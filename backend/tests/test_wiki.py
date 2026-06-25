import uuid
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic import ValidationError
from sqlalchemy import delete, inspect, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.source import Source
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.models.wiki import WikiCitation, WikiPage
from app.schemas.sources import SourceCreate
from app.schemas.wiki import WikiCompileRequest
from app.services.sources import create_or_update_source
from app.services.wiki import (
    CitationDraft,
    build_backlink_map,
    format_citation_reference,
    render_index_page,
    render_section,
    slugify,
)


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def wiki_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        test_emails = ["wiki-user@example.com", "other-wiki-user@example.com"]
        await session.execute(delete(User).where(User.email.in_(test_emails)))

        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Wiki User",
            email="wiki-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        other_user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Other Wiki User",
            email="other-wiki-user@example.com",
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
async def wiki_client(
    wiki_session: tuple[AsyncSession, User, User],
) -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User], None]:
    session, user, other_user = wiki_session

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
    tags: list[str],
    chunks: list[tuple[str, str]],
) -> Source:
    source = await create_or_update_source(
        user,
        SourceCreate(
            source_type="markdown",
            origin="fixture",
            external_id=f"{title.lower().replace(' ', '-')}-{uuid.uuid4()}",
            title=title,
            citation_label=f"{title} Citation",
            topic_tags=tags,
            status="ready",
        ),
        session,
    )
    for index, (location_label, content) in enumerate(chunks):
        session.add(
            SourceChunk(
                source_id=source.id,
                chunk_index=index,
                citation_ref=f"{source.citation_label}: {location_label}",
                location_label=location_label,
                content=content,
                token_count=len(content.split()),
                embedding=[0.1] * 1536,
            )
        )
    await session.commit()
    await session.refresh(source, attribute_names=["chunks"])
    return source


def test_slugify_normalizes_titles():
    assert slugify(" Week 1: Limits & Continuity ") == "week-1-limits-continuity"
    assert slugify("!!!") == "page"


def test_compile_request_rejects_empty_source_ids():
    with pytest.raises(ValidationError):
        WikiCompileRequest(source_ids=[])


def test_render_section_adds_citation_marker():
    assert render_section("Limits", "Limits describe behavior.", "c1") == (
        "## Limits\n\nLimits describe behavior. [^c1]"
    )


def test_format_citation_reference_traces_chunk():
    citation = CitationDraft(
        citation_key="c2",
        citation_ref="Notes: Continuity",
        source_id=uuid.uuid4(),
        source_chunk_id=uuid.uuid4(),
        source_title="Week 1 Notes",
        location_label="Continuity",
        chunk_index=1,
        snippet="Continuity matches values.",
    )

    assert format_citation_reference(citation) == (
        "[^c2]: Notes: Continuity (Week 1 Notes, Continuity, chunk 2)"
    )


def test_backlink_generation_uses_overlapping_topics():
    from app.services.wiki import PageDraft

    limits = PageDraft(
        title="Limits",
        slug="limits",
        summary="",
        source_ids=[uuid.uuid4()],
        topic_tags=["calculus"],
        sections=["## Definition"],
        citations=[],
    )
    continuity = PageDraft(
        title="Continuity",
        slug="continuity",
        summary="",
        source_ids=[uuid.uuid4()],
        topic_tags=["calculus"],
        sections=["## Definition"],
        citations=[],
    )
    algebra = PageDraft(
        title="Algebra",
        slug="algebra",
        summary="",
        source_ids=[uuid.uuid4()],
        topic_tags=["algebra"],
        sections=["## Definition"],
        citations=[],
    )

    backlinks = build_backlink_map([limits, continuity, algebra])

    assert backlinks["limits"] == ["continuity"]
    assert backlinks["continuity"] == ["limits"]
    assert backlinks["algebra"] == []


def test_backlink_generation_ignores_slug_substrings_without_wiki_links():
    from app.services.wiki import PageDraft

    short_title = PageDraft(
        title="AI",
        slug="ai",
        summary="",
        source_ids=[uuid.uuid4()],
        topic_tags=[],
        sections=["## Topic"],
        citations=[],
    )
    chair = PageDraft(
        title="Chair Notes",
        slug="chair-notes",
        summary="",
        source_ids=[uuid.uuid4()],
        topic_tags=[],
        sections=["The chair is blue."],
        citations=[],
    )

    backlinks = build_backlink_map([short_title, chair])

    assert backlinks["ai"] == []
    assert backlinks["chair-notes"] == []


def test_index_generation_lists_pages_and_coverage():
    from app.services.wiki import PageDraft

    page = PageDraft(
        title="Limits",
        slug="limits",
        summary="",
        source_ids=[uuid.uuid4()],
        topic_tags=["calculus"],
        sections=[],
        citations=[
            CitationDraft(
                citation_key="c1",
                citation_ref="Limits Citation",
                source_id=uuid.uuid4(),
                source_chunk_id=uuid.uuid4(),
                source_title="Limits",
                location_label="",
                chunk_index=0,
                snippet="Limits describe behavior.",
            )
        ],
        backlinks=["continuity"],
    )

    markdown = render_index_page([page])

    assert "# Workspace Wiki Index" in markdown
    assert "[[Limits]] (`limits`) — 1 citations" in markdown
    assert "Limits: 1 source, 1 citations" in markdown
    assert "[[Limits]] ← continuity" in markdown


@pytest.mark.asyncio
async def test_compile_wiki_stores_pages_citations_backlinks_and_index(wiki_client):
    client, session, user, _ = wiki_client
    limits = await _create_ready_source(
        session,
        user,
        "Limits Notes",
        ["calculus"],
        [("Definition", "Limits describe behavior near a point.")],
    )
    continuity = await _create_ready_source(
        session,
        user,
        "Continuity Notes",
        ["calculus"],
        [("Rule", "Continuity requires matching values and limits.")],
    )

    response = await client.post("/api/wiki/compile", json={})

    assert response.status_code == 200
    pages = response.json()["pages"]
    assert [page["slug"] for page in pages] == [
        "index",
        "continuity-notes",
        "limits-notes",
    ]

    limits_page = next(page for page in pages if page["slug"] == "limits-notes")
    assert "Limits describe behavior" in limits_page["markdown"]
    assert "[^c1]" in limits_page["markdown"]
    assert "## References" in limits_page["markdown"]
    assert limits_page["citations"][0]["source_id"] == str(limits.id)
    assert limits_page["citations"][0]["source_chunk_id"] is not None
    assert limits_page["backlinks"] == ["continuity-notes"]

    index_page = next(page for page in pages if page["slug"] == "index")
    assert "## Source coverage" in index_page["markdown"]
    assert set(index_page["source_ids"]) == {str(limits.id), str(continuity.id)}
    assert index_page["citation_count"] == 2

    stored_citations = (await session.execute(select(WikiCitation))).scalars().all()
    assert len(stored_citations) == 2


@pytest.mark.asyncio
async def test_recompile_updates_changed_source_and_keeps_user_scope(wiki_client):
    client, session, user, other_user = wiki_client
    source = await _create_ready_source(
        session,
        user,
        "Mutable Notes",
        ["testing"],
        [("Original", "Original source text.")],
    )
    other_source = await _create_ready_source(
        session,
        other_user,
        "Private Notes",
        ["testing"],
        [("Private", "Private source text.")],
    )

    first_response = await client.post("/api/wiki/compile")
    assert first_response.status_code == 200

    chunk = source.chunks[0]
    chunk.content = "Updated source text with new evidence."
    chunk.citation_ref = "Mutable Notes Citation: Updated"
    await session.commit()

    second_response = await client.post("/api/wiki/compile", json={"source_ids": [str(source.id)]})

    assert second_response.status_code == 200
    pages = second_response.json()["pages"]
    mutable_page = next(page for page in pages if page["slug"] == "mutable-notes")
    assert "Updated source text" in mutable_page["markdown"]
    assert "Original source text" not in mutable_page["markdown"]
    assert "Private source text" not in "\n".join(page["markdown"] for page in pages)

    stored_pages = (await session.execute(select(WikiPage))).scalars().all()
    assert {page.user_id for page in stored_pages} == {user.id}
    assert other_source.id not in {
        source_id for page in stored_pages for source_id in page.source_ids
    }


@pytest.mark.asyncio
async def test_scoped_recompile_preserves_existing_owned_pages(wiki_client):
    client, session, user, _ = wiki_client
    first = await _create_ready_source(
        session,
        user,
        "First Notes",
        ["planning"],
        [("Overview", "First source text.")],
    )
    second = await _create_ready_source(
        session,
        user,
        "Second Notes",
        ["planning"],
        [("Overview", "Second source text.")],
    )

    first_response = await client.post("/api/wiki/compile", json={"source_ids": [str(first.id)]})
    assert first_response.status_code == 200
    assert {page["slug"] for page in first_response.json()["pages"]} == {
        "index",
        "first-notes",
    }

    second_response = await client.post(
        "/api/wiki/compile",
        json={"source_ids": [str(second.id)]},
    )

    assert second_response.status_code == 200
    pages = second_response.json()["pages"]
    assert {page["slug"] for page in pages} == {"index", "first-notes", "second-notes"}
    assert "First source text" in next(
        page["markdown"] for page in pages if page["slug"] == "first-notes"
    )
    assert "Second source text" in next(
        page["markdown"] for page in pages if page["slug"] == "second-notes"
    )


@pytest.mark.asyncio
async def test_wiki_schema_has_required_tables_and_indexes(wiki_session):
    session, _, _ = wiki_session

    async with session.bind.connect() as connection:
        page_indexes = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_indexes("wiki_pages")
        )
        citation_indexes = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_indexes("wiki_citations")
        )
        page_columns = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_columns("wiki_pages")
        )
        citation_columns = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_columns("wiki_citations")
        )

    assert {"slug", "markdown", "source_ids", "citation_count", "backlinks"} <= {
        column["name"] for column in page_columns
    }
    assert {"source_id", "source_chunk_id", "citation_ref", "snippet"} <= {
        column["name"] for column in citation_columns
    }
    assert {"ix_wiki_pages_user_slug", "ix_wiki_pages_source_ids"} <= {
        index["name"] for index in page_indexes
    }
    assert {"ix_wiki_citations_page_id", "ix_wiki_citations_source_chunk_id"} <= {
        index["name"] for index in citation_indexes
    }
