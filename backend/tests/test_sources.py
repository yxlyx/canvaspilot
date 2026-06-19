import uuid
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, inspect, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.source import Source
from app.models.user import User
from app.schemas.sources import SourceCreate, SourceUpdate
from app.services.sources import create_or_update_source, update_source


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def source_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        test_emails = ["source-user@example.com", "other-source-user@example.com"]
        await session.execute(delete(User).where(User.email.in_(test_emails)))

        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Source User",
            email="source-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        other_user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Other User",
            email="other-source-user@example.com",
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
async def source_client(
    source_session: tuple[AsyncSession, User, User],
) -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User], None]:
    session, user, other_user = source_session

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


@pytest.mark.asyncio
async def test_create_source_normalizes_metadata(source_client):
    client, _, user, _ = source_client

    response = await client.post(
        "/api/sources",
        json={
            "source_type": "markdown",
            "origin": " upload ",
            "external_id": " notes-1 ",
            "title": " Week 1 Notes ",
            "topic_tags": [" Math ", "math", "", "Limits"],
        },
    )

    assert response.status_code == 201
    data = response.json()
    assert data["user_id"] == str(user.id)
    assert data["origin"] == "upload"
    assert data["external_id"] == "notes-1"
    assert data["title"] == "Week 1 Notes"
    assert data["citation_label"] == "Week 1 Notes"
    assert data["topic_tags"] == ["math", "limits"]
    assert data["status"] == "pending"


@pytest.mark.asyncio
async def test_list_sources_filters_and_isolates_users(source_client):
    client, session, user, other_user = source_client
    await create_or_update_source(
        user,
        SourceCreate(
            source_type="markdown",
            origin="upload",
            external_id="notes-1",
            title="Week 1 Notes",
            topic_tags=["algebra"],
            status="ready",
        ),
        session,
    )
    await create_or_update_source(
        user,
        SourceCreate(
            source_type="pdf",
            origin="upload",
            external_id="slides-1",
            title="Lecture Slides",
            topic_tags=["geometry"],
            status="pending",
        ),
        session,
    )
    await create_or_update_source(
        other_user,
        SourceCreate(
            source_type="markdown",
            origin="upload",
            external_id="other-notes",
            title="Other Notes",
            topic_tags=["algebra"],
            status="ready",
        ),
        session,
    )

    response = await client.get("/api/sources", params={"source_type": "markdown"})

    assert response.status_code == 200
    data = response.json()
    assert [source["title"] for source in data] == ["Week 1 Notes"]

    response = await client.get("/api/sources", params={"status": "pending"})
    assert response.status_code == 200
    assert [source["title"] for source in response.json()] == ["Lecture Slides"]

    response = await client.get("/api/sources", params={"topic_tag": "algebra"})
    assert response.status_code == 200
    assert [source["title"] for source in response.json()] == ["Week 1 Notes"]


@pytest.mark.asyncio
async def test_get_and_patch_source_require_owner(source_client):
    client, session, user, other_user = source_client
    source = await create_or_update_source(
        user,
        SourceCreate(
            source_type="link",
            origin="web",
            external_id="https://example.com/a",
            title="Reading",
            source_url="https://example.com/a",
        ),
        session,
    )
    other_source = await create_or_update_source(
        other_user,
        SourceCreate(
            source_type="link",
            origin="web",
            external_id="https://example.com/b",
            title="Private Reading",
            source_url="https://example.com/b",
        ),
        session,
    )

    response = await client.get(f"/api/sources/{source.id}")
    assert response.status_code == 200
    assert response.json()["title"] == "Reading"

    response = await client.patch(
        f"/api/sources/{source.id}",
        json={
            "title": "Updated Reading",
            "citation_label": "Custom Citation",
            "topic_tags": [" Week 2 ", "week 2"],
            "status": "ready",
        },
    )
    assert response.status_code == 200
    data = response.json()
    assert data["title"] == "Updated Reading"
    assert data["citation_label"] == "Custom Citation"
    assert data["topic_tags"] == ["week 2"]
    assert data["status"] == "ready"

    response = await client.get(f"/api/sources/{other_source.id}")
    assert response.status_code == 404

    response = await client.patch(f"/api/sources/{other_source.id}", json={"title": "Nope"})
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_reimport_preserves_user_edited_metadata(source_session):
    session, user, _ = source_session
    source = await create_or_update_source(
        user,
        SourceCreate(
            source_type="repository",
            origin="github",
            external_id="repo-1",
            title="Original Repo",
            source_url="https://example.com/repo",
            citation_label="Custom Repo",
            topic_tags=["systems"],
            course_context="CS2100",
            project_context="Project A",
            status="ready",
        ),
        session,
    )
    source = await update_source(
        source,
        SourceUpdate(
            citation_label="Edited Label",
            topic_tags=["edited"],
            course_context="CS2103T",
            project_context="Project B",
        ),
        session,
    )

    imported = await create_or_update_source(
        user,
        SourceCreate(
            source_type="repository",
            origin="github",
            external_id="repo-1",
            title="Renamed Repo",
            source_url="https://example.com/repo-renamed",
            citation_label="Incoming Label",
            topic_tags=["incoming"],
            course_context="Incoming Course",
            project_context="Incoming Project",
            status="indexing",
        ),
        session,
    )

    assert imported.id == source.id
    assert imported.title == "Renamed Repo"
    assert imported.source_url == "https://example.com/repo-renamed"
    assert imported.status == "indexing"
    assert imported.citation_label == "Edited Label"
    assert imported.topic_tags == ["edited"]
    assert imported.course_context == "CS2103T"
    assert imported.project_context == "Project B"


@pytest.mark.asyncio
async def test_sources_schema_has_required_indexes(source_session):
    session, _, _ = source_session

    async with session.bind.connect() as connection:
        indexes = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_indexes("sources")
        )
        columns = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_columns("sources")
        )

    column_names = {column["name"] for column in columns}
    assert {
        "user_id",
        "source_type",
        "origin",
        "external_id",
        "title",
        "citation_label",
        "topic_tags",
        "status",
        "updated_at",
    } <= column_names

    index_names = {index["name"] for index in indexes}
    assert {
        "ix_sources_user_updated_at",
        "ix_sources_user_source_type",
        "ix_sources_user_status",
        "ix_sources_user_title",
        "ix_sources_topic_tags",
        "uq_sources_user_origin_external",
    } <= index_names
