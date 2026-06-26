import uuid
from collections.abc import AsyncGenerator
from types import SimpleNamespace

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from sqlalchemy import delete, inspect, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.flashcard import Flashcard, FlashcardDeck, LearningEvidence
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.models.wiki import WikiCitation, WikiPage
from app.schemas.flashcards import FlashcardAttemptCreate, FlashcardGenerateRequest
from app.schemas.sources import SourceCreate
from app.services.flashcards import _candidate_from_wiki_citation
from app.services.sources import create_or_update_source


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def flashcard_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        test_emails = ["flashcard-user@example.com", "other-flashcard-user@example.com"]
        await session.execute(delete(User).where(User.email.in_(test_emails)))

        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Flashcard User",
            email="flashcard-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        other_user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Other Flashcard User",
            email="other-flashcard-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        session.add_all([user, other_user])
        await session.commit()
        user_id = user.id
        other_user_id = other_user.id

        try:
            yield session, user, other_user
        finally:
            await session.rollback()
            await session.execute(
                delete(FlashcardDeck).where(FlashcardDeck.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(
                delete(WikiPage).where(WikiPage.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(
                delete(Source).where(Source.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(delete(User).where(User.id.in_([user_id, other_user_id])))
            await session.commit()

    await engine.dispose()


@pytest.fixture
async def flashcard_client(
    flashcard_session: tuple[AsyncSession, User, User],
) -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User], None]:
    session, user, other_user = flashcard_session

    async def override_get_current_user():
        return user

    async def override_get_db():
        yield session

    app.dependency_overrides[get_current_user] = override_get_current_user
    app.dependency_overrides[get_db] = override_get_db

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client, session, user, other_user

    app.dependency_overrides.clear()


async def _create_ready_source(
    session: AsyncSession,
    user: User,
    title: str = "Limits Notes",
    chunks: list[str] | None = None,
    topic_tags: list[str] | None = None,
) -> tuple[Source, list[SourceChunk]]:
    source = await create_or_update_source(
        user,
        SourceCreate(
            source_type="markdown",
            origin="flashcard-test",
            external_id=f"{title.lower().replace(' ', '-')}-{uuid.uuid4()}",
            title=title,
            source_url=f"https://example.com/{title.lower().replace(' ', '-')}",
            citation_label=f"{title} Citation",
            topic_tags=topic_tags or ["calculus", "limits"],
            status=SourceStatus.READY,
        ),
        session,
    )
    chunk_texts = chunks or [
        "Limits describe function behavior near a point and help define continuity.",
        "One-sided limits compare behavior from the left and right of a point.",
    ]
    source_chunks = [
        SourceChunk(
            source_id=source.id,
            chunk_index=index,
            citation_ref=f"{source.citation_label}: Section {index + 1}",
            location_label=f"Section {index + 1}",
            content=content,
            token_count=len(content.split()),
            embedding=None,
        )
        for index, content in enumerate(chunk_texts)
    ]
    session.add_all(source_chunks)
    await session.commit()
    await session.refresh(source)
    for chunk in source_chunks:
        await session.refresh(chunk)
    return source, source_chunks


async def _create_wiki_page(
    session: AsyncSession,
    user: User,
    source: Source,
    chunk: SourceChunk,
) -> WikiPage:
    page = WikiPage(
        user_id=user.id,
        slug="limits-summary",
        title="Limits Summary",
        page_type="source",
        markdown="Limits describe nearby function behavior with source-backed citations.",
        summary="A source-backed limits overview.",
        source_ids=[source.id],
        citation_count=1,
        backlinks=[],
    )
    session.add(page)
    await session.flush()
    citation = WikiCitation(
        page_id=page.id,
        source_id=source.id,
        source_chunk_id=chunk.id,
        citation_key="S1",
        citation_ref=chunk.citation_ref,
        source_title=source.title,
        location_label=chunk.location_label,
        chunk_index=chunk.chunk_index,
        snippet=chunk.content,
    )
    session.add(citation)
    await session.commit()
    await session.refresh(page, attribute_names=["citations"])
    return page


def test_generate_request_requires_one_scope():
    with pytest.raises(ValidationError):
        FlashcardGenerateRequest()
    with pytest.raises(ValidationError):
        FlashcardGenerateRequest(source_ids=[uuid.uuid4()], source_chunk_ids=[uuid.uuid4()])
    with pytest.raises(ValidationError):
        FlashcardGenerateRequest(source_ids=[uuid.uuid4()], topic="limits")
    with pytest.raises(ValidationError):
        FlashcardGenerateRequest(source_chunk_ids=[uuid.uuid4()], unexpected="value")


def test_wiki_candidate_uses_cited_section_when_citation_snippet_is_too_short():
    source_id = uuid.uuid4()
    chunk_id = uuid.uuid4()
    page = WikiPage(
        id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        slug="limits-summary",
        title="Limits Summary",
        page_type="source",
        markdown=(
            "# Limits Summary\n\n"
            "> Limits describe function behavior near a point.\n\n"
            "## Derivatives\n\n"
            "Note. Derivatives measure instantaneous rates of change for functions. [^c2]\n\n"
            "## References\n\n"
            "[^c2]: Derivatives Citation: Section 2"
        ),
        summary="Limits describe function behavior near a point.",
        source_ids=[source_id],
        citation_count=1,
        backlinks=[],
    )
    citation = SimpleNamespace(
        citation_key="c2",
        snippet="Note.",
        citation_ref="Derivatives Citation: Section 2",
        source_title="Derivatives Notes",
        source_id=source_id,
        source_chunk_id=chunk_id,
        location_label="Section 2",
    )

    candidate = _candidate_from_wiki_citation(page, citation)

    assert "Derivatives measure instantaneous rates" in candidate.content
    assert "Limits describe function behavior" not in candidate.content
    assert candidate.citation_ref == "Derivatives Citation: Section 2"
    assert candidate.source_chunk_id == chunk_id


@pytest.mark.asyncio
async def test_generate_flashcards_from_sources_preserves_citations(flashcard_client):
    client, session, user, _ = flashcard_client
    source, chunks = await _create_ready_source(session, user)

    response = await client.post(
        "/api/flashcards/decks/generate",
        json={"source_ids": [str(source.id)], "limit": 3},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["message"] == "Flashcard deck generated."
    assert data["generated_count"] == 2
    deck = data["deck"]
    assert deck["generation_scope"] == "sources"
    assert deck["source_ids"] == [str(source.id)]
    assert deck["card_count"] == 2
    assert {card["card_type"] for card in deck["cards"]} == {"short_answer", "concept_check"}
    first_card = deck["cards"][0]
    assert first_card["source_id"] == str(source.id)
    assert first_card["source_chunk_id"] == str(chunks[0].id)
    assert first_card["citation_ref"] == "Limits Notes Citation: Section 1"
    assert first_card["topic_tag"] == "calculus"
    assert "Limits describe" in first_card["answer"]

    stored_cards = (
        (await session.execute(select(Flashcard).where(Flashcard.deck_id == uuid.UUID(deck["id"]))))
        .scalars()
        .all()
    )
    assert len(stored_cards) == 2


@pytest.mark.asyncio
async def test_generate_flashcards_from_selected_source_chunks_only(flashcard_client):
    client, session, user, _ = flashcard_client
    source, chunks = await _create_ready_source(session, user)

    response = await client.post(
        "/api/flashcards/decks/generate",
        json={"source_chunk_ids": [str(chunks[1].id), str(chunks[0].id)], "limit": 3},
    )

    assert response.status_code == 200
    deck = response.json()["deck"]
    assert deck["generation_scope"] == "source_chunks"
    assert deck["source_ids"] == [str(source.id)]
    assert deck["card_count"] == 2
    assert [card["source_chunk_id"] for card in deck["cards"]] == [
        str(chunks[1].id),
        str(chunks[0].id),
    ]
    assert [card["order_index"] for card in deck["cards"]] == [1, 2]
    assert deck["cards"][0]["citation_ref"] == chunks[1].citation_ref
    assert "One sided limits" in deck["cards"][0]["answer"]


@pytest.mark.asyncio
async def test_generate_flashcards_from_wiki_page_preserves_source_citation(flashcard_client):
    client, session, user, _ = flashcard_client
    source, chunks = await _create_ready_source(session, user)
    page = await _create_wiki_page(session, user, source, chunks[0])

    response = await client.post(
        "/api/flashcards/decks/generate",
        json={"wiki_page_id": str(page.id), "limit": 5},
    )

    assert response.status_code == 200
    deck = response.json()["deck"]
    assert deck["generation_scope"] == "wiki_page"
    assert deck["wiki_page_id"] == str(page.id)
    assert deck["source_ids"] == [str(source.id)]
    assert deck["cards"][0]["wiki_page_id"] == str(page.id)
    assert deck["cards"][0]["source_chunk_id"] == str(chunks[0].id)
    assert deck["cards"][0]["citation_ref"] == chunks[0].citation_ref


@pytest.mark.asyncio
async def test_generate_flashcards_by_topic_filters_ready_sources(flashcard_client):
    client, session, user, other_user = flashcard_client
    source, _ = await _create_ready_source(
        session, user, title="Continuity Notes", topic_tags=["continuity"]
    )
    await _create_ready_source(session, user, title="Derivatives Notes", topic_tags=["derivatives"])
    await _create_ready_source(
        session, other_user, title="Private Continuity", topic_tags=["continuity"]
    )

    response = await client.post(
        "/api/flashcards/decks/generate",
        json={"topic": " Continuity ", "limit": 10},
    )

    assert response.status_code == 200
    deck = response.json()["deck"]
    assert deck["generation_scope"] == "topic"
    assert deck["source_ids"] == [str(source.id)]
    assert deck["topic_tags"] == ["continuity"]
    assert all(card["source_id"] == str(source.id) for card in deck["cards"])


@pytest.mark.asyncio
async def test_generate_flashcards_by_topic_labels_cards_with_requested_topic(flashcard_client):
    client, session, user, _ = flashcard_client
    source, _ = await _create_ready_source(
        session, user, title="Limits Notes", topic_tags=["calculus", "limits"]
    )

    response = await client.post(
        "/api/flashcards/decks/generate",
        json={"topic": "limits", "limit": 10},
    )

    assert response.status_code == 200
    deck = response.json()["deck"]
    assert deck["source_ids"] == [str(source.id)]
    assert deck["topic_tags"] == ["limits"]
    assert all(card["topic_tag"] == "limits" for card in deck["cards"]), [
        card["topic_tag"] for card in deck["cards"]
    ]


@pytest.mark.asyncio
async def test_low_context_generation_returns_clear_fallback(flashcard_client):
    client, session, user, _ = flashcard_client
    source, _ = await _create_ready_source(
        session, user, chunks=["Too short."], topic_tags=["brief"]
    )

    response = await client.post(
        "/api/flashcards/decks/generate",
        json={"source_ids": [str(source.id)]},
    )

    assert response.status_code == 200
    assert response.json() == {
        "deck": None,
        "generated_count": 0,
        "message": "Not enough cited source context to generate flashcards.",
    }
    decks = (
        (await session.execute(select(FlashcardDeck).where(FlashcardDeck.user_id == user.id)))
        .scalars()
        .all()
    )
    assert decks == []


@pytest.mark.asyncio
async def test_attempt_logging_creates_learning_evidence(flashcard_client):
    client, session, user, _ = flashcard_client
    source, chunks = await _create_ready_source(session, user)
    deck_response = await client.post(
        "/api/flashcards/decks/generate",
        json={"source_ids": [str(source.id)], "limit": 1},
    )
    card = deck_response.json()["deck"]["cards"][0]

    response = await client.post(
        f"/api/flashcards/cards/{card['id']}/attempts",
        json={"answer_text": "behavior near a point", "is_correct": True, "confidence": 4},
    )

    assert response.status_code == 200
    attempt = response.json()
    assert attempt["card_id"] == card["id"]
    assert attempt["is_correct"] is True
    assert attempt["confidence"] == 4
    evidence = attempt["evidence"]
    assert evidence["evidence_type"] == "flashcard_attempt"
    assert evidence["topic_tag"] == "calculus"
    assert evidence["source_id"] == str(source.id)
    assert evidence["source_chunk_id"] == str(chunks[0].id)
    assert evidence["flashcard_id"] == card["id"]
    assert evidence["citation_ref"] == chunks[0].citation_ref

    stored_evidence = (
        await session.execute(select(LearningEvidence).where(LearningEvidence.user_id == user.id))
    ).scalar_one()
    assert stored_evidence.flashcard_attempt_id == uuid.UUID(attempt["id"])

    evidence_response = await client.get(
        "/api/flashcards/evidence", params={"topic_tag": "calculus"}
    )
    assert evidence_response.status_code == 200
    assert evidence_response.json()[0]["id"] == evidence["id"]


@pytest.mark.asyncio
async def test_flashcard_generation_and_attempts_are_user_scoped(flashcard_client):
    client, session, user, other_user = flashcard_client
    other_source, other_chunks = await _create_ready_source(
        session, other_user, title="Private Notes"
    )

    generate_response = await client.post(
        "/api/flashcards/decks/generate",
        json={"source_ids": [str(other_source.id)]},
    )
    assert generate_response.status_code == 404

    chunk_generate_response = await client.post(
        "/api/flashcards/decks/generate",
        json={"source_chunk_ids": [str(other_chunks[0].id)]},
    )
    assert chunk_generate_response.status_code == 404

    other_deck = FlashcardDeck(
        user_id=other_user.id,
        title="Private Deck",
        description="",
        generation_scope="sources",
        source_ids=[other_source.id],
        topic_tags=["calculus"],
        card_count=1,
    )
    session.add(other_deck)
    await session.flush()
    other_card = Flashcard(
        deck_id=other_deck.id,
        user_id=other_user.id,
        source_id=other_source.id,
        source_chunk_id=other_chunks[0].id,
        order_index=1,
        card_type="short_answer",
        question="Private question?",
        answer="Private answer.",
        topic_tag="calculus",
        citation_ref=other_chunks[0].citation_ref,
        source_title=other_source.title,
        location_label=other_chunks[0].location_label,
    )
    session.add(other_card)
    await session.commit()

    attempt_response = await client.post(
        f"/api/flashcards/cards/{other_card.id}/attempts",
        json={"is_correct": False},
    )
    assert attempt_response.status_code == 404

    decks_response = await client.get("/api/flashcards/decks")
    assert decks_response.status_code == 200
    assert decks_response.json() == []


def test_attempt_schema_validates_confidence():
    with pytest.raises(ValidationError):
        FlashcardAttemptCreate(is_correct=True, confidence=6)


@pytest.mark.asyncio
async def test_flashcard_tables_and_indexes_exist(flashcard_session):
    session, _, _ = flashcard_session

    async with session.bind.connect() as connection:
        table_names = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_table_names()
        )
        deck_indexes = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_indexes("flashcard_decks")
        )
        evidence_indexes = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_indexes("learning_evidence")
        )

    assert "flashcard_decks" in table_names
    assert "flashcards" in table_names
    assert "flashcard_attempts" in table_names
    assert "learning_evidence" in table_names

    deck_index_names = {index["name"] for index in deck_indexes}
    evidence_index_names = {index["name"] for index in evidence_indexes}
    assert "ix_flashcard_decks_user_updated_at" in deck_index_names
    assert "ix_learning_evidence_user_topic" in evidence_index_names
    assert "uq_learning_evidence_flashcard_attempt" in evidence_index_names
