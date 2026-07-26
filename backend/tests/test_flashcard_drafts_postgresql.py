import asyncio
import uuid
from collections.abc import AsyncGenerator
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.curriculum import (
    CatalogModule,
    CurriculumTopic,
    ModuleEnrollment,
    ProviderModuleSnapshot,
    SemesterOffering,
    TopicSourceAssociation,
)
from app.models.flashcard import FlashcardDeck, FlashcardRevision
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.models.wiki import WikiCitation, WikiPage
from app.schemas.flashcards import FlashcardAttemptCreate
from app.schemas.sources import SourceCreate
from app.services.flashcards import log_flashcard_attempt
from app.services.sources import create_or_update_source

pytestmark = pytest.mark.usefixtures("mock_flashcard_provider")


@pytest.fixture
async def draft_client() -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        try:
            await session.execute(text("SELECT 1"))
        except (OSError, SQLAlchemyError) as exc:
            pytest.skip(f"database is unavailable: {exc}")

        email = f"flashcard-draft-{uuid.uuid4()}@example.com"
        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Flashcard Draft User",
            email=email,
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        session.add(user)
        await session.commit()
        user_id = user.id

        async def override_get_current_user():
            return user

        async def override_get_db():
            yield session

        app.dependency_overrides[get_current_user] = override_get_current_user
        app.dependency_overrides[get_db] = override_get_db
        transport = ASGITransport(app=app)
        try:
            async with AsyncClient(transport=transport, base_url="http://test") as client:
                yield client, session, user
        finally:
            app.dependency_overrides.clear()
            await session.rollback()
            await session.execute(delete(User).where(User.id == user_id))
            await session.commit()
    await engine.dispose()


async def _ready_source(session: AsyncSession, user: User) -> tuple[Source, list[SourceChunk]]:
    source = await create_or_update_source(
        user,
        SourceCreate(
            source_type="markdown",
            origin="draft-postgresql-test",
            external_id=str(uuid.uuid4()),
            title="Concurrency Notes",
            source_url="https://example.com/concurrency",
            citation_label="Concurrency Notes",
            topic_tags=["concurrency"],
            status=SourceStatus.READY,
        ),
        session,
    )
    chunks = [
        SourceChunk(
            source_id=source.id,
            chunk_index=0,
            citation_ref="Concurrency Notes: Locks",
            location_label="Locks",
            content=(
                "Database row locks serialize competing writers before a consistent "
                "snapshot is read."
            ),
            token_count=12,
            embedding=None,
        ),
        SourceChunk(
            source_id=source.id,
            chunk_index=1,
            citation_ref="Concurrency Notes: Ordering",
            location_label="Ordering",
            content=(
                "Stable secondary keys make result ordering deterministic when primary "
                "values are equal."
            ),
            token_count=12,
            embedding=None,
        ),
    ]
    session.add_all(chunks)
    await session.commit()
    await session.refresh(source)
    for chunk in chunks:
        await session.refresh(chunk)
    return source, chunks


async def _wiki_page(
    session: AsyncSession, user: User, source: Source, chunk: SourceChunk
) -> WikiPage:
    page = WikiPage(
        user_id=user.id,
        slug=f"concurrency-{uuid.uuid4()}",
        title="Concurrency",
        page_type="source",
        markdown="Database row locks serialize competing writers. [^S1]",
        summary="Concurrency summary.",
        source_ids=[source.id],
        citation_count=1,
        backlinks=[],
    )
    session.add(page)
    await session.flush()
    session.add(
        WikiCitation(
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
    )
    await session.commit()
    return page


def _error(response, status: int, error: str) -> None:
    assert response.status_code == status, response.text
    assert response.json()["error"] == error


@pytest.mark.asyncio
async def test_draft_review_lifecycle_snapshots_counts_and_attempts(draft_client):
    client, session, user = draft_client
    source, chunks = await _ready_source(session, user)
    generated = await client.post(
        "/api/flashcards/decks/generate",
        json={"source_chunk_ids": [str(chunks[0].id)], "limit": 1},
    )
    assert generated.status_code == 200
    deck = generated.json()["deck"]
    generated_card = deck["cards"][0]
    assert deck["card_count"] == 1
    assert deck["approved_snapshot"] is None

    outside_scope = await client.patch(
        f"/api/flashcards/drafts/{deck['id']}/cards/{generated_card['id']}",
        json={
            "expected_revision": deck["revision"],
            "citations": [
                {
                    "source_id": str(source.id),
                    "source_chunk_id": str(chunks[1].id),
                }
            ],
        },
    )
    _error(outside_scope, 422, "citation_out_of_scope")

    discarded = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/discard",
        json={"expected_revision": deck["revision"], "card_ids": [generated_card["id"]]},
    )
    assert discarded.status_code == 200
    deck = discarded.json()
    assert deck["card_count"] == 0
    assert deck["cards"][0]["state"] == "discarded"
    stale_revision = await client.patch(
        f"/api/flashcards/drafts/{deck['id']}",
        json={"expected_revision": deck["revision"] - 1, "title": "Stale title"},
    )
    _error(stale_revision, 409, "revision_conflict")

    restored = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/restore",
        json={"expected_revision": deck["revision"], "card_ids": [generated_card["id"]]},
    )
    assert restored.status_code == 200
    deck = restored.json()
    assert deck["card_count"] == 1

    added = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/cards",
        json={
            "expected_revision": deck["revision"],
            "question": "What should I remember?",
            "answer": "Acquire locks in a stable order.",
            "manual_note": True,
        },
    )
    assert added.status_code == 200
    deck = added.json()
    manual_card = next(card for card in deck["cards"] if card["manual_note"])
    assert deck["card_count"] == 2

    reordered = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/reorder",
        json={
            "expected_revision": deck["revision"],
            "card_ids": [manual_card["id"], generated_card["id"]],
        },
    )
    assert reordered.status_code == 200
    deck = reordered.json()
    assert [card["id"] for card in deck["cards"]] == [manual_card["id"], generated_card["id"]]

    discarded_after_reorder = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/discard",
        json={"expected_revision": deck["revision"], "card_ids": [manual_card["id"]]},
    )
    assert discarded_after_reorder.status_code == 200
    deck = discarded_after_reorder.json()
    reordered_active = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/reorder",
        json={"expected_revision": deck["revision"], "card_ids": [generated_card["id"]]},
    )
    assert reordered_active.status_code == 200
    deck = reordered_active.json()
    restored_after_reorder = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/restore",
        json={"expected_revision": deck["revision"], "card_ids": [manual_card["id"]]},
    )
    assert restored_after_reorder.status_code == 200
    deck = restored_after_reorder.json()
    assert [card["id"] for card in deck["cards"]] == [generated_card["id"], manual_card["id"]]
    assert [card["order_index"] for card in deck["cards"]] == [1, 2]

    added_for_discard = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/cards",
        json={
            "expected_revision": deck["revision"],
            "question": "Which card should not be published?",
            "answer": "This discarded personal note.",
            "manual_note": True,
        },
    )
    assert added_for_discard.status_code == 200
    deck = added_for_discard.json()
    discarded_card = next(
        card for card in deck["cards"] if card["question"] == "Which card should not be published?"
    )
    discarded_for_publication = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/discard",
        json={"expected_revision": deck["revision"], "card_ids": [discarded_card["id"]]},
    )
    assert discarded_for_publication.status_code == 200
    deck = discarded_for_publication.json()

    approved = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/approve",
        json={
            "expected_revision": deck["revision"],
            "card_ids": [manual_card["id"], generated_card["id"]],
        },
    )
    assert approved.status_code == 200
    deck = approved.json()
    published = await client.post(
        f"/api/flashcards/decks/{deck['id']}/publish",
        json={"expected_revision": deck["revision"]},
    )
    assert published.status_code == 200
    deck = published.json()
    snapshot = deck["approved_snapshot"]
    assert snapshot["id"] == deck["id"]
    assert snapshot["lifecycle"] == "approved"
    assert snapshot["revision"] == deck["revision"]
    assert snapshot["approved_at"] == deck["approved_at"].replace("Z", "+00:00")
    assert snapshot["scope_snapshot"] == deck["scope_snapshot"]
    assert snapshot["generator_snapshot"] == deck["generator_snapshot"]
    assert snapshot["card_count"] == 2
    assert [card["id"] for card in snapshot["cards"] if card["state"] == "active"] == [
        generated_card["id"],
        manual_card["id"],
    ]
    assert [card["id"] for card in snapshot["cards"] if card["state"] == "discarded"] == [
        discarded_card["id"]
    ]
    assert snapshot["updated_at"] == deck["updated_at"].replace("Z", "+00:00")

    immutable = await client.patch(
        f"/api/flashcards/drafts/{deck['id']}",
        json={"expected_revision": deck["revision"], "title": "Changed"},
    )
    _error(immutable, 409, "deck_immutable")

    attempt = await client.post(
        f"/api/flashcards/cards/{generated_card['id']}/attempts",
        headers={"Idempotency-Key": "draft-lifecycle-attempt"},
        json={"rating": "Good", "answer_text": "A consistent snapshot"},
    )
    assert attempt.status_code == 200
    repeated = await client.post(
        f"/api/flashcards/cards/{generated_card['id']}/attempts",
        headers={"Idempotency-Key": "draft-lifecycle-attempt"},
        json={"rating": "Good", "answer_text": "A consistent snapshot"},
    )
    assert repeated.status_code == 200
    assert repeated.json()["id"] == attempt.json()["id"]

    async def concurrent_attempt():
        async with async_session_factory() as concurrent_session:
            concurrent_user = await concurrent_session.get(User, user.id)
            assert concurrent_user is not None
            return await log_flashcard_attempt(
                concurrent_user,
                uuid.UUID(generated_card["id"]),
                FlashcardAttemptCreate(
                    rating="Easy", answer_text="Serialized by the deck lock", confidence=5
                ),
                "concurrent-same-key",
                concurrent_session,
            )

    concurrent_attempts = await asyncio.gather(concurrent_attempt(), concurrent_attempt())
    assert concurrent_attempts[0].id == concurrent_attempts[1].id

    changed_request = await client.post(
        f"/api/flashcards/cards/{generated_card['id']}/attempts",
        headers={"Idempotency-Key": "draft-lifecycle-attempt"},
        json={
            "rating": "Good",
            "answer_text": "A consistent snapshot",
            "confidence": 4,
        },
    )
    _error(changed_request, 409, "idempotency_conflict")

    retired = await client.post(
        f"/api/flashcards/decks/{deck['id']}/retire",
        json={"expected_revision": deck["revision"]},
    )
    assert retired.status_code == 200
    replayed_after_retirement = await client.post(
        f"/api/flashcards/cards/{generated_card['id']}/attempts",
        headers={"Idempotency-Key": "draft-lifecycle-attempt"},
        json={"rating": "Good", "answer_text": "A consistent snapshot"},
    )
    assert replayed_after_retirement.status_code == 200
    assert replayed_after_retirement.json()["id"] == attempt.json()["id"]
    blocked_after_retirement = await client.post(
        f"/api/flashcards/cards/{generated_card['id']}/attempts",
        headers={"Idempotency-Key": "new-retired-attempt"},
        json={"rating": "Good", "answer_text": "A consistent snapshot"},
    )
    _error(blocked_after_retirement, 409, "deck_not_approved")

    revisions = list(
        (
            await session.execute(
                select(FlashcardRevision)
                .where(FlashcardRevision.deck_id == uuid.UUID(deck["id"]))
                .order_by(FlashcardRevision.revision)
            )
        ).scalars()
    )
    assert [revision.action for revision in revisions] == [
        "discard",
        "restore",
        "add_card",
        "reorder",
        "discard",
        "reorder",
        "restore",
        "add_card",
        "discard",
        "approve",
        "publish",
        "retired",
    ]


@pytest.mark.asyncio
async def test_wiki_draft_accepts_only_snapshotted_chunk_page_pairs(draft_client):
    client, session, user = draft_client
    source, chunks = await _ready_source(session, user)
    page = await _wiki_page(session, user, source, chunks[0])
    generated = await client.post(
        "/api/flashcards/decks/generate",
        json={"wiki_page_id": str(page.id), "limit": 1},
    )
    assert generated.status_code == 200
    deck = generated.json()["deck"]
    card = deck["cards"][0]
    provenance = deck["scope_snapshot"]["ordered_provenance"]
    assert provenance[0]["wiki_page_id"] == str(page.id)

    missing_page = await client.patch(
        f"/api/flashcards/drafts/{deck['id']}/cards/{card['id']}",
        json={
            "expected_revision": deck["revision"],
            "citations": [
                {
                    "source_id": str(source.id),
                    "source_chunk_id": str(chunks[0].id),
                }
            ],
        },
    )
    _error(missing_page, 422, "citation_out_of_scope")

    session.add(
        WikiCitation(
            page_id=page.id,
            source_id=source.id,
            source_chunk_id=chunks[1].id,
            citation_key="S2",
            citation_ref=chunks[1].citation_ref,
            source_title=source.title,
            location_label=chunks[1].location_label,
            chunk_index=chunks[1].chunk_index,
            snippet=chunks[1].content,
        )
    )
    await session.commit()
    added_after_snapshot = await client.patch(
        f"/api/flashcards/drafts/{deck['id']}/cards/{card['id']}",
        json={
            "expected_revision": deck["revision"],
            "citations": [
                {
                    "source_id": str(source.id),
                    "source_chunk_id": str(chunks[1].id),
                    "wiki_page_id": str(page.id),
                }
            ],
        },
    )
    _error(added_after_snapshot, 422, "citation_out_of_scope")

    approved = await client.post(
        f"/api/flashcards/drafts/{deck['id']}/approve",
        json={"expected_revision": deck["revision"], "card_ids": [card["id"]]},
    )
    assert approved.status_code == 200
    canonical = approved.json()["cards"][0]["citations"][0]
    assert canonical["source_chunk_id"] == str(chunks[0].id)
    assert canonical["wiki_page_id"] == str(page.id)
    assert canonical["citation_ref"] == chunks[0].citation_ref

    stored = await session.get(FlashcardDeck, uuid.UUID(deck["id"]))
    assert stored is not None
    assert stored.card_count == 1


@pytest.mark.database
@pytest.mark.asyncio
async def test_topic_order_returns_same_draft_and_fingerprint(draft_client):
    client, session, user = draft_client
    source, _chunks = await _ready_source(session, user)
    suffix = uuid.uuid4().hex[:8].upper()
    catalog = CatalogModule(
        institution="Test University",
        canonical_code=f"T{suffix}",
        code=f"T{suffix}",
        title="Canonical Topics",
        description="Topic ordering regression fixture",
        metadata_json={},
    )
    snapshot = ProviderModuleSnapshot(
        provider="fixture",
        academic_year="2025-2026",
        module_code=f"T{suffix}",
        provider_version="v1",
        source_url="https://example.test/module",
        fetched_at=datetime.now(UTC),
        payload_sha256="a" * 64,
        payload={"title": "Canonical Topics"},
    )
    offering = SemesterOffering(
        catalog_module=catalog,
        provider_snapshot=snapshot,
        academic_year="2025-2026",
        semester=1,
        metadata_json={},
    )
    enrollment = ModuleEnrollment(
        user_id=user.id,
        offering=offering,
        provenance="manual",
        import_method="manual_codes",
        topic_state="canonical",
        lesson_config={},
    )
    session.add_all([catalog, snapshot, offering, enrollment])
    await session.flush()
    topics = [
        CurriculumTopic(
            enrollment_id=enrollment.id,
            position=position,
            title=title,
            state="canonical",
            provenance="user_review",
            extraction_rule="manual-review-v1",
            extraction_rule_hash="b" * 64,
            source_text=title,
            source_sha256=str(position) * 64,
        )
        for position, title in enumerate(["Locks", "Stable ordering"])
    ]
    session.add_all(topics)
    await session.flush()
    session.add_all(
        [
            TopicSourceAssociation(
                enrollment_id=enrollment.id,
                topic_id=topic.id,
                source_id=source.id,
                status="confirmed",
                method="manual",
                evidence_strength=1.0,
                algorithm="manual",
                rule_hash="c" * 64,
                source_fingerprint="d" * 64,
                topic_fingerprint="e" * 64,
                evidence=[],
                reason_code="manual_confirmation",
                reviewed_at=datetime.now(UTC),
                reviewer_id=user.id,
            )
            for topic in topics
        ]
    )
    await session.commit()

    first = await client.post(
        "/api/flashcards/decks/generate",
        json={"topic_ids": [str(topics[0].id), str(topics[1].id)], "limit": 1},
    )
    assert first.status_code == 200, first.text
    first_deck = first.json()["deck"]

    reversed_order = await client.post(
        "/api/flashcards/decks/generate",
        json={"topic_ids": [str(topics[1].id), str(topics[0].id)], "limit": 1},
    )
    assert reversed_order.status_code == 200, reversed_order.text
    reversed_deck = reversed_order.json()["deck"]

    assert reversed_deck["id"] == first_deck["id"]
    assert reversed_deck["input_fingerprint"] == first_deck["input_fingerprint"]

    await session.delete(enrollment)
    await session.flush()
    await session.delete(offering)
    await session.delete(catalog)
    await session.delete(snapshot)
    await session.commit()
