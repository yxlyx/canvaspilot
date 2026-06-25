import uuid
from collections.abc import AsyncGenerator
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.content import ContentChunk, SourceType
from app.models.module import Module
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.models.wiki import WikiPage
from app.schemas.sources import SourceCreate
from app.services.search import _boosted_vector_score
from app.services.sources import create_or_update_source


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def search_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        test_emails = ["search-user@example.com", "other-search-user@example.com"]
        await session.execute(delete(User).where(User.email.in_(test_emails)))

        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Search User",
            email="search-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        other_user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Other Search User",
            email="other-search-user@example.com",
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
                delete(WikiPage).where(WikiPage.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(
                delete(Source).where(Source.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(delete(User).where(User.id.in_([user_id, other_user_id])))
            await session.commit()

    await engine.dispose()


@pytest.fixture
async def search_client(
    search_session: tuple[AsyncSession, User, User],
) -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User], None]:
    session, user, other_user = search_session

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
            origin="search-test",
            external_id=f"{title.lower().replace(' ', '-')}-{uuid.uuid4()}",
            title=title,
            source_url=f"https://example.com/{title.lower().replace(' ', '-')}",
            citation_label=f"{title} Citation",
            topic_tags=["calculus", "search"],
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


async def _create_module_chunk(
    session: AsyncSession,
    user: User,
    title: str,
    content: str,
    embedding: list[float],
) -> ContentChunk:
    module = Module(
        canvas_course_id=9001,
        user_id=user.id,
        name="Search Fixture Module",
        code="SEARCH101",
        term="M2",
    )
    session.add(module)
    await session.flush()
    chunk = ContentChunk(
        module_id=module.id,
        source_type=SourceType.PAGE,
        source_id=f"module-page-{uuid.uuid4()}",
        source_title=title,
        source_url="https://example.com/module-page",
        content=content,
        token_count=len(content.split()),
        embedding=embedding,
    )
    session.add(chunk)
    await session.commit()
    await session.refresh(chunk)
    return chunk


async def _create_wiki_page(session: AsyncSession, user: User, source: Source) -> WikiPage:
    page = WikiPage(
        user_id=user.id,
        slug="limits-summary",
        title="Limits Summary",
        page_type="source",
        markdown="Limits describe function behavior near a point with cited source notes.",
        summary="A source-backed limits overview.",
        source_ids=[source.id],
        citation_count=1,
        backlinks=[],
    )
    session.add(page)
    await session.commit()
    await session.refresh(page)
    return page


def _basis_vector(index: int) -> list[float]:
    vector = [0.0] * 1536
    vector[index] = 1.0
    return vector


async def _query_embedding() -> list[float]:
    return _basis_vector(0)


def test_vector_score_is_normalized_for_old_chunks():
    old_row = SimpleNamespace(created_at=datetime.now(UTC) - timedelta(days=1200))

    score = _boosted_vector_score(old_row, 1.0)

    assert 0.0 <= score <= 1.0
    assert score == 0.85


@pytest.mark.asyncio
async def test_workspace_search_returns_ranked_source_and_wiki_results(search_client, monkeypatch):
    client, session, user, other_user = search_client
    monkeypatch.setattr("app.services.search.embed_query", lambda _: _query_embedding())
    source, chunk = await _create_ready_source(
        session,
        user,
        "Limits Notes",
        "Limits describe function behavior near a point.",
        _basis_vector(0),
        "Limits Notes Citation: Definition",
    )
    wiki_page = await _create_wiki_page(session, user, source)
    await _create_ready_source(
        session,
        other_user,
        "Limits Private Notes",
        "Private limits content must stay hidden.",
        _basis_vector(0),
        "Private Notes Citation: Hidden",
    )

    response = await client.get("/api/search", params={"query": "limits", "limit": 10})

    assert response.status_code == 200
    data = response.json()
    assert data["query"] == "limits"
    results = data["results"]
    assert [result["result_type"] for result in results] == [
        "source_chunk",
        "source",
        "wiki_page",
    ]

    chunk_result = results[0]
    assert chunk_result["title"] == "Limits Notes"
    assert chunk_result["source_id"] == str(source.id)
    assert chunk_result["source_chunk_id"] == str(chunk.id)
    assert chunk_result["citation_ref"] == "Limits Notes Citation: Definition"
    assert "function behavior" in chunk_result["snippet"]
    assert chunk_result["score"] > results[1]["score"]

    source_result = results[1]
    assert source_result["result_type"] == "source"
    assert source_result["citation_ref"] == "Limits Notes Citation"
    assert source_result["url"] == source.source_url

    wiki_result = results[2]
    assert wiki_result["wiki_page_id"] == str(wiki_page.id)
    assert wiki_result["wiki_slug"] == "limits-summary"
    assert wiki_result["url"] == "/wiki/limits-summary"
    assert "Private" not in " ".join(result["snippet"] for result in results)


@pytest.mark.asyncio
async def test_workspace_search_includes_module_content_chunks(search_client, monkeypatch):
    client, session, user, other_user = search_client
    monkeypatch.setattr("app.services.search.embed_query", lambda _: _query_embedding())
    chunk = await _create_module_chunk(
        session,
        user,
        "Limits Module Page",
        "Limits also appear in synced module page content.",
        _basis_vector(0),
    )
    await _create_module_chunk(
        session,
        other_user,
        "Private Module Page",
        "Private limits content must stay out of search results.",
        _basis_vector(0),
    )

    response = await client.get("/api/search", params={"query": "limits"})

    assert response.status_code == 200
    results = response.json()["results"]
    assert len(results) == 1
    assert results[0]["result_type"] == "content_chunk"
    assert results[0]["content_chunk_id"] == str(chunk.id)
    assert results[0]["source_chunk_id"] is None
    assert results[0]["title"] == "Limits Module Page"
    assert "Private" not in results[0]["snippet"]


@pytest.mark.asyncio
async def test_workspace_search_falls_back_to_metadata_when_embeddings_fail(
    search_client,
    monkeypatch,
):
    client, session, user, _ = search_client

    async def broken_embedding(_: str) -> list[float]:
        raise RuntimeError("embedding unavailable")

    monkeypatch.setattr("app.services.search.embed_query", broken_embedding)
    source, _ = await _create_ready_source(
        session,
        user,
        "Limits Notes",
        "This chunk would require vector search, but title search still works.",
        _basis_vector(0),
        "Limits Notes Citation: Definition",
    )

    response = await client.get("/api/search", params={"query": "limits"})

    assert response.status_code == 200
    results = response.json()["results"]
    assert [result["result_type"] for result in results] == ["source"]
    assert results[0]["source_id"] == str(source.id)
    assert results[0]["score"] <= 1.0


@pytest.mark.asyncio
async def test_workspace_search_returns_clear_empty_results(search_client, monkeypatch):
    client, session, user, _ = search_client
    monkeypatch.setattr("app.services.search.embed_query", lambda _: _query_embedding())
    await _create_ready_source(
        session,
        user,
        "Orthogonal Notes",
        "This source is indexed but unrelated to the query.",
        _basis_vector(1),
        "Orthogonal Notes Citation: Topic",
    )

    response = await client.get("/api/search", params={"query": "limits"})

    assert response.status_code == 200
    assert response.json() == {"query": "limits", "results": []}


@pytest.mark.asyncio
async def test_workspace_search_is_user_scoped(search_client, monkeypatch):
    client, session, _, other_user = search_client
    monkeypatch.setattr("app.services.search.embed_query", lambda _: _query_embedding())
    await _create_ready_source(
        session,
        other_user,
        "Limits Private Notes",
        "Private limits content must not appear in another workspace.",
        _basis_vector(0),
        "Private Notes Citation: Hidden",
    )

    response = await client.get("/api/search", params={"query": "limits"})

    assert response.status_code == 200
    assert response.json()["results"] == []


@pytest.mark.asyncio
async def test_workspace_search_rejects_blank_query(search_client):
    client, _, _, _ = search_client

    response = await client.get("/api/search", params={"query": ""})
    whitespace_response = await client.get("/api/search", params={"query": "   "})

    assert response.status_code == 422
    assert whitespace_response.status_code == 422
