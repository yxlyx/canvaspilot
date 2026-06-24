import json
import uuid
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.schemas.sources import SourceCreate
from app.services import llm
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

    transport = ASGITransport(app=app)
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
        def __init__(self, api_key: str):
            self.chat = FakeChat()

    monkeypatch.setattr(llm, "AsyncOpenAI", FakeOpenAI)


def _parse_sse_events(response_text: str) -> list[tuple[str, dict]]:
    events: list[tuple[str, dict]] = []
    for block in response_text.strip().split("\n\n"):
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
        }
    ]
    done = events[-1][1]
    assert done["grounded"] is True
    assert done["confidence"] > 0.9
    system_context = captured["messages"][0]["content"]
    assert "Limits describe function behavior" in system_context
    assert "Private content" not in system_context


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
