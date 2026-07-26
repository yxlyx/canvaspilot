import json
import uuid
from collections.abc import AsyncGenerator
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.exceptions import NotFoundError
from app.main import app
from app.models.curriculum import (
    CatalogModule,
    CurriculumTopic,
    ModuleEnrollment,
    ProviderModuleSnapshot,
    SemesterOffering,
    TopicSourceAssociation,
)
from app.models.processing import SourceVersion
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.models.wiki import WikiPage
from app.schemas.sources import SourceCreate
from app.services import llm
from app.services.curriculum_coverage import coverage_dashboard, topic_fingerprint
from app.services.retrieval import retrieve
from app.services.sources import create_or_update_source


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def retrieval_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        test_emails = ["retrieval-user@example.com", "other-retrieval-user@example.com"]
        await session.execute(delete(User).where(User.email.in_(test_emails)))

        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Retrieval User",
            email="retrieval-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        other_user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Other Retrieval User",
            email="other-retrieval-user@example.com",
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
                delete(Source).where(Source.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(delete(User).where(User.id.in_([user_id, other_user_id])))
            await session.commit()

    await engine.dispose()


@pytest.fixture
async def retrieval_client(
    retrieval_session: tuple[AsyncSession, User, User],
) -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User], None]:
    session, user, other_user = retrieval_session

    async def override_get_current_user():
        return user

    async def override_get_db():
        yield session

    app.dependency_overrides[get_current_user] = override_get_current_user
    app.dependency_overrides[get_db] = override_get_db

    async def asgi_24_app(scope, receive, send):
        scope = {**scope, "asgi": {**scope["asgi"], "spec_version": "2.4"}}
        await app(scope, receive, send)

    transport = ASGITransport(app=asgi_24_app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client, session, user, other_user

    app.dependency_overrides.clear()


async def _create_ready_source(
    session: AsyncSession,
    user: User,
    title: str,
    content: str,
    embedding: list[float],
    citation_ref: str | None = None,
) -> tuple[Source, SourceChunk]:
    source = await create_or_update_source(
        user,
        SourceCreate(
            source_type="markdown",
            origin="retrieval-test",
            external_id=f"{title.lower().replace(' ', '-')}-{uuid.uuid4()}",
            title=title,
            source_url=f"https://example.com/{title.lower().replace(' ', '-')}",
            citation_label=f"{title} Citation",
            topic_tags=["retrieval"],
            status=SourceStatus.READY,
        ),
        session,
    )
    chunk = SourceChunk(
        source_id=source.id,
        chunk_index=0,
        citation_ref=citation_ref or f"{source.citation_label}: Section 1",
        location_label="Section 1",
        content=content,
        token_count=len(content.split()),
        embedding=embedding,
    )
    session.add(chunk)
    await session.commit()
    await session.refresh(source)
    await session.refresh(chunk)
    return source, chunk


async def _create_enrollment(
    session: AsyncSession,
    user: User,
    code: str,
) -> tuple[ModuleEnrollment, CurriculumTopic]:
    catalog = CatalogModule(
        institution="Test University",
        canonical_code=code,
        code=code,
        title=f"{code} Retrieval",
        description="Enrollment-scoped retrieval fixture.",
        metadata_json={},
    )
    snapshot = ProviderModuleSnapshot(
        provider="fixture",
        academic_year="2025-2026",
        module_code=code,
        provider_version="v1",
        source_url=f"https://example.com/modules/{code}",
        fetched_at=datetime.now(UTC),
        payload_sha256=uuid.uuid4().hex * 2,
        payload={"title": catalog.title},
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
    topic = CurriculumTopic(
        enrollment_id=enrollment.id,
        position=0,
        title="Scoped retrieval",
        state="canonical",
        provenance="user_review",
        extraction_rule="manual-review-v1",
        extraction_rule_hash="a" * 64,
        source_text="Scoped retrieval",
        source_sha256="b" * 64,
    )
    session.add(topic)
    await session.commit()
    return enrollment, topic


def _basis_vector(index: int) -> list[float]:
    vector = [0.0] * 1536
    vector[index] = 1.0
    return vector


async def _query_embedding() -> list[float]:
    return _basis_vector(0)


class FakeDelta:
    def __init__(self, content: str):
        self.content = content


class FakeChoice:
    def __init__(self, content: str):
        self.delta = FakeDelta(content)


class FakeStreamChunk:
    def __init__(self, content: str):
        self.choices = [FakeChoice(content)]


async def _fake_stream(parts: list[str]):
    for part in parts:
        yield FakeStreamChunk(part)


def _install_fake_chat_completion(monkeypatch, parts: list[str], captured: dict):
    class FakeCompletions:
        async def create(self, **kwargs):
            captured["messages"] = kwargs["messages"]
            return _fake_stream(parts)

    class FakeChat:
        completions = FakeCompletions()

    class FakeOpenAI:
        def __init__(self, api_key: str, **kwargs):
            captured["api_key"] = api_key
            captured.update(kwargs)
            self.chat = FakeChat()

    monkeypatch.setattr(llm, "AsyncOpenAI", FakeOpenAI)


def _parse_sse_events(response_text: str) -> list[tuple[str, dict]]:
    events: list[tuple[str, dict]] = []
    normalized_text = response_text.replace("\r\n", "\n")
    for block in normalized_text.strip().split("\n\n"):
        event_name = "message"
        data_lines: list[str] = []
        for line in block.splitlines():
            if line.startswith("event: "):
                event_name = line.removeprefix("event: ")
            elif line.startswith("data: "):
                data_lines.append(line.removeprefix("data: "))
        if data_lines:
            events.append((event_name, json.loads("\n".join(data_lines))))
    return events


@pytest.mark.asyncio
async def test_retrieve_ranks_fixture_source_chunks(retrieval_session, monkeypatch):
    session, user, _ = retrieval_session
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())
    source, _ = await _create_ready_source(
        session,
        user,
        "Limits Notes",
        "Limits describe function behavior near a point.",
        _basis_vector(0),
        "Limits Notes Citation: Definition",
    )
    await _create_ready_source(
        session,
        user,
        "Unrelated Notes",
        "This source is about a different topic.",
        _basis_vector(1),
        "Unrelated Notes Citation: Topic",
    )

    chunks = await retrieve("What are limits?", user.id, session, top_k=5)

    assert len(chunks) == 1
    assert chunks[0].source_title == "Limits Notes"
    assert chunks[0].source_id == str(source.id)
    assert chunks[0].citation_ref == "Limits Notes Citation: Definition"
    assert "function behavior" in chunks[0].content


@pytest.mark.asyncio
async def test_enrollment_scope_enforces_ownership_associations_and_active_versions(
    retrieval_client, monkeypatch
):
    client, session, user, other_user = retrieval_client
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())
    suffix = uuid.uuid4().hex[:8].upper()
    enrollment, topic = await _create_enrollment(session, user, f"R{suffix}A")
    other_enrollment, _ = await _create_enrollment(session, user, f"R{suffix}B")
    foreign_enrollment, _ = await _create_enrollment(session, other_user, f"R{suffix}C")

    direct, _ = await _create_ready_source(
        session, user, "Direct Scoped", "Direct enrollment evidence.", _basis_vector(0)
    )
    direct.enrollment_id = enrollment.id
    cross_enrollment, _ = await _create_ready_source(
        session, user, "Other Enrollment", "Cross-enrollment evidence.", _basis_vector(0)
    )
    cross_enrollment.enrollment_id = other_enrollment.id
    confirmed, confirmed_chunk = await _create_ready_source(
        session, user, "Confirmed Unscoped", "Confirmed topic evidence.", _basis_vector(0)
    )
    proposed, proposed_chunk = await _create_ready_source(
        session, user, "Proposed Unscoped", "Proposed topic evidence.", _basis_vector(0)
    )
    stale, stale_chunk = await _create_ready_source(
        session, user, "Stale Unscoped", "Stale topic evidence.", _basis_vector(0)
    )
    versioned, old_chunk = await _create_ready_source(
        session, user, "Versioned Unscoped", "Historical version evidence.", _basis_vector(0)
    )

    reviewed_at = datetime.now(UTC)
    for source, chunk, status, is_stale in [
        (confirmed, confirmed_chunk, "confirmed", False),
        (proposed, proposed_chunk, "proposed", False),
        (stale, stale_chunk, "confirmed", True),
        (versioned, old_chunk, "confirmed", False),
    ]:
        session.add(
            TopicSourceAssociation(
                enrollment_id=enrollment.id,
                topic_id=topic.id,
                source_id=source.id,
                status=status,
                method="manual",
                evidence_strength=1.0,
                algorithm="manual-v1",
                rule_hash="c" * 64,
                source_fingerprint="d" * 64,
                topic_fingerprint=topic_fingerprint(topic),
                evidence=[
                    {
                        "chunk_id": str(chunk.id),
                        "citation": chunk.citation_ref,
                        "excerpt": chunk.content,
                        "location": chunk.location_label,
                    }
                ],
                reason_code="manual_confirmation",
                stale=is_stale,
                stale_reason="source_chunks_changed" if is_stale else None,
                reviewed_at=reviewed_at if status == "confirmed" else None,
                reviewer_id=user.id if status == "confirmed" else None,
            )
        )

    old_version = SourceVersion(
        source_id=versioned.id,
        version_number=1,
        fingerprint="1" * 64,
        payload={},
        status="ready",
        ready_at=reviewed_at,
    )
    current_version = SourceVersion(
        source_id=versioned.id,
        version_number=2,
        fingerprint="2" * 64,
        payload={},
        status="ready",
        ready_at=reviewed_at,
    )
    session.add_all([old_version, current_version])
    await session.flush()
    old_chunk.source_version_id = old_version.id
    versioned.current_version_id = current_version.id
    session.add(
        SourceChunk(
            source_id=versioned.id,
            source_version_id=current_version.id,
            chunk_index=0,
            citation_ref="Versioned Scoped: Current",
            location_label="Current",
            content="Current but unrelated evidence.",
            token_count=4,
            embedding=_basis_vector(1),
        )
    )
    session.add_all(
        [
            WikiPage(
                user_id=user.id,
                slug=f"direct-{suffix.lower()}",
                title="Direct enrollment Wiki",
                page_type="source",
                markdown=(
                    "# Direct enrollment Wiki\n\n"
                    "## Backlinks\n\n"
                    "This source section explains backlink data structures.\n\n"
                    "## Overview\n\nDirect scoped content.\n\n"
                    "## Backlinks\n\n"
                    "- [[Related enrollment Wiki]]\n- [[Other [draft] enrollment Wiki]]\n\n"
                    "## References\n\n[^c1]: Direct source\n"
                ),
                summary="Direct scoped page.",
                source_ids=[direct.id],
                citation_count=0,
                backlinks=[f"related-{suffix.lower()}", f"other-{suffix.lower()}"],
            ),
            WikiPage(
                user_id=user.id,
                slug=f"related-{suffix.lower()}",
                title="Related enrollment Wiki",
                page_type="source",
                markdown="# Related enrollment Wiki",
                summary="Another direct scoped page.",
                source_ids=[direct.id],
                citation_count=0,
                backlinks=[f"direct-{suffix.lower()}"],
            ),
            WikiPage(
                user_id=user.id,
                slug=f"confirmed-{suffix.lower()}",
                title="Confirmed evidence Wiki",
                page_type="source",
                markdown="# Confirmed evidence Wiki",
                summary="Confirmed unscoped evidence page.",
                source_ids=[confirmed.id],
                citation_count=0,
                backlinks=[],
            ),
            WikiPage(
                user_id=user.id,
                slug=f"other-{suffix.lower()}",
                title="Other [draft] enrollment Wiki",
                page_type="source",
                markdown="# Other [draft] enrollment Wiki",
                summary="Cross-enrollment page.",
                source_ids=[cross_enrollment.id],
                citation_count=0,
                backlinks=[],
            ),
        ]
    )
    await session.commit()

    chunks = await retrieve(
        "What belongs to this enrollment?",
        user.id,
        session,
        enrollment_id=enrollment.id,
        top_k=20,
    )
    titles = {chunk.source_title for chunk in chunks}
    assert titles == {"Direct Scoped", "Confirmed Unscoped"}
    assert "Other Enrollment" not in titles
    assert "Proposed Unscoped" not in titles
    assert "Stale Unscoped" not in titles
    assert "Versioned Unscoped" not in titles

    wiki_response = await client.get(
        "/api/wiki/pages", params={"enrollment_id": str(enrollment.id)}
    )
    assert wiki_response.status_code == 200
    assert [page["title"] for page in wiki_response.json()] == [
        "Confirmed evidence Wiki",
        "Direct enrollment Wiki",
        "Related enrollment Wiki",
    ]
    direct_page = next(page for page in wiki_response.json() if page["title"].startswith("Direct"))
    assert direct_page["backlinks"] == [f"related-{suffix.lower()}"]
    assert "[[Related enrollment Wiki]]" in direct_page["markdown"]
    assert "Other [draft] enrollment Wiki" not in direct_page["markdown"]
    assert "This source section explains backlink data structures." in direct_page["markdown"]
    assert direct_page["markdown"].count("## Backlinks") == 2
    assert "## References" in direct_page["markdown"]
    direct_response = await client.get(
        f"/api/wiki/pages/direct-{suffix.lower()}",
        params={"enrollment_id": str(enrollment.id)},
    )
    assert direct_response.status_code == 200
    assert direct_response.json()["backlinks"] == [f"related-{suffix.lower()}"]

    topic.title = "Revised scoped retrieval"
    await session.flush()
    dashboard = await coverage_dashboard(enrollment, session)
    assert dashboard["topics"][0]["state"] == "missing"
    confirmed_evidence = dashboard["topics"][0]["confirmed_sources"]
    assert any(
        item["source_id"] == confirmed.id
        and item["stale"]
        and item["stale_reason"] == "topic_revised"
        for item in confirmed_evidence
    )
    revised_chunks = await retrieve(
        "What remains after the topic revision?",
        user.id,
        session,
        enrollment_id=enrollment.id,
        top_k=20,
    )
    assert {chunk.source_title for chunk in revised_chunks} == {"Direct Scoped"}
    revised_wiki_response = await client.get(
        "/api/wiki/pages", params={"enrollment_id": str(enrollment.id)}
    )
    assert [page["title"] for page in revised_wiki_response.json()] == [
        "Direct enrollment Wiki",
        "Related enrollment Wiki",
    ]

    excluded_response = await client.get(
        f"/api/wiki/pages/other-{suffix.lower()}",
        params={"enrollment_id": str(enrollment.id)},
    )
    assert excluded_response.status_code == 404
    foreign_wiki_response = await client.get(
        "/api/wiki/pages", params={"enrollment_id": str(foreign_enrollment.id)}
    )
    assert foreign_wiki_response.status_code == 404

    with pytest.raises(NotFoundError, match="Active module enrollment not found"):
        await retrieve(
            "What belongs to this enrollment?",
            user.id,
            session,
            enrollment_id=foreign_enrollment.id,
        )
    response = await client.post(
        "/api/chat",
        json={
            "message": "What belongs to this enrollment?",
            "enrollment_id": str(foreign_enrollment.id),
        },
    )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_chat_returns_cited_answer_from_source_chunks(retrieval_client, monkeypatch):
    client, session, user, other_user = retrieval_client
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())
    captured: dict = {}
    _install_fake_chat_completion(
        monkeypatch,
        ["Limits describe nearby function behavior ", "using the notes [1]."],
        captured,
    )
    source, chunk = await _create_ready_source(
        session,
        user,
        "Limits Notes",
        "Limits describe function behavior near a point.",
        _basis_vector(0),
        "Limits Notes Citation: Definition",
    )
    await _create_ready_source(
        session,
        other_user,
        "Private Notes",
        "Private content must not be cited.",
        _basis_vector(0),
        "Private Notes Citation: Hidden",
    )

    response = await client.post("/api/chat", json={"message": "What are limits?"})

    assert response.status_code == 200
    events = _parse_sse_events(response.text)
    assert [event for event, _ in events] == ["token", "token", "citations", "done"]
    answer_text = "".join(data["text"] for event, data in events if event == "token")
    assert "Limits describe" in answer_text
    citations = next(data["citations"] for event, data in events if event == "citations")
    assert citations == [
        {
            "title": "Limits Notes",
            "url": source.source_url,
            "snippet": chunk.content[:200],
            "source_id": str(source.id),
            "citation_ref": "Limits Notes Citation: Definition",
            "reference_number": 1,
        }
    ]
    done = events[-1][1]
    assert done["grounded"] is True
    assert done["confidence"] > 0.9
    system_context = captured["messages"][0]["content"]
    assert "Limits describe function behavior" in system_context
    assert "Private content" not in system_context


@pytest.mark.asyncio
async def test_chat_preserves_sparse_repeated_reference_numbers(retrieval_client, monkeypatch):
    client, session, user, _ = retrieval_client
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())
    captured: dict = {}
    _install_fake_chat_completion(
        monkeypatch,
        ["The first and third sources support this [3], then [1], again [3]."],
        captured,
    )
    for title in ["Reference Alpha", "Reference Beta", "Reference Gamma"]:
        await _create_ready_source(
            session,
            user,
            title,
            f"{title} contains relevant evidence.",
            _basis_vector(0),
        )

    response = await client.post("/api/chat", json={"message": "Compare the references"})

    assert response.status_code == 200
    events = _parse_sse_events(response.text)
    citations = next(data["citations"] for event, data in events if event == "citations")
    assert [citation["reference_number"] for citation in citations] == [1, 3]
    assert len(citations) == 2


@pytest.mark.asyncio
async def test_chat_no_relevant_source_returns_safe_fallback(retrieval_client, monkeypatch):
    client, session, _, other_user = retrieval_client
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())
    await _create_ready_source(
        session,
        other_user,
        "Private Notes",
        "Private content must not be used as fallback context.",
        _basis_vector(0),
        "Private Notes Citation: Hidden",
    )

    response = await client.post("/api/chat", json={"message": "What are limits?"})

    assert response.status_code == 200
    events = _parse_sse_events(response.text)
    assert events == [
        (
            "done",
            {
                "grounded": False,
                "confidence": 0,
                "message": "No relevant content found in your workspace sources.",
            },
        )
    ]


@pytest.mark.asyncio
async def test_chat_filters_low_similarity_source_chunks(retrieval_client, monkeypatch):
    client, session, user, _ = retrieval_client
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())
    await _create_ready_source(
        session,
        user,
        "Orthogonal Notes",
        "This indexed source should be below the relevance threshold.",
        _basis_vector(1),
        "Orthogonal Notes Citation: Topic",
    )

    response = await client.post("/api/chat", json={"message": "What are limits?"})

    assert response.status_code == 200
    events = _parse_sse_events(response.text)
    assert events[-1][1]["grounded"] is False
    assert events[-1][1]["message"] == "No relevant content found in your workspace sources."


@pytest.mark.asyncio
async def test_chat_persists_citation_shape_in_schema():
    from app.schemas.chat import Citation

    citation = Citation(
        title="Limits Notes",
        url="https://example.com/limits-notes",
        snippet="Limits describe behavior.",
        source_id=str(uuid.uuid4()),
        citation_ref="Limits Notes Citation: Definition",
    )

    assert citation.model_dump()["citation_ref"] == "Limits Notes Citation: Definition"
