import uuid
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, inspect, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.ingestion_job import IngestionJob
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.schemas.sources import SourceCreate
from app.services.ingestion_jobs import create_queued_ingestion_job
from app.services.retrieval import retrieve
from app.services.sources import create_or_update_source


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def source_import_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        test_emails = ["import-user@example.com", "other-import-user@example.com"]
        await session.execute(delete(User).where(User.email.in_(test_emails)))

        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Import User",
            email="import-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        other_user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Other Import User",
            email="other-import-user@example.com",
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
                delete(IngestionJob).where(IngestionJob.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(
                delete(Source).where(Source.user_id.in_([user_id, other_user_id]))
            )
            await session.execute(delete(User).where(User.id.in_([user_id, other_user_id])))
            await session.commit()

    await engine.dispose()


@pytest.fixture
async def source_import_client(
    source_import_session: tuple[AsyncSession, User, User],
) -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User], None]:
    session, user, other_user = source_import_session

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


async def _create_source(session: AsyncSession, user: User, title: str) -> Source:
    return await create_or_update_source(
        user,
        SourceCreate(
            source_type="markdown",
            origin="upload",
            external_id=f"{title.lower().replace(' ', '-')}-{uuid.uuid4()}",
            title=title,
            citation_label=f"{title} Citation",
        ),
        session,
    )


async def _fake_embed_chunks(chunks: list[SourceChunk], db: AsyncSession) -> None:
    for chunk in chunks:
        chunk.embedding = [0.1] * 1536
    await db.commit()


@pytest.mark.asyncio
async def test_run_ingestion_job_imports_source_chunks(source_import_client, monkeypatch):
    client, session, user, _ = source_import_client
    monkeypatch.setattr("app.services.source_imports.embed_chunks", _fake_embed_chunks)

    source = await _create_source(session, user, "Week 1 Notes")
    job = await create_queued_ingestion_job(user, [source.id], session)

    response = await client.post(
        f"/api/ingestion/jobs/{job.id}/run",
        json={
            "sources": [
                {
                    "source_id": str(source.id),
                    "content": (
                        "Limits describe behavior near a point. "
                        "Continuity requires the limit to match the function value."
                    ),
                }
            ]
        },
    )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "completed"
    assert data["imported_source_count"] == 1
    assert data["chunk_count"] == 1

    await session.refresh(source)
    assert source.status == SourceStatus.READY
    assert source.import_error is None
    assert source.last_imported_at is not None

    chunks = (
        (await session.execute(select(SourceChunk).where(SourceChunk.source_id == source.id)))
        .scalars()
        .all()
    )
    assert len(chunks) == 1
    assert chunks[0].chunk_index == 0
    assert chunks[0].citation_ref == "Week 1 Notes Citation#1"
    assert list(chunks[0].embedding) == [0.1] * 1536


@pytest.mark.asyncio
async def test_run_ingestion_job_replaces_stale_chunks(source_import_client, monkeypatch):
    client, session, user, _ = source_import_client
    monkeypatch.setattr("app.services.source_imports.embed_chunks", _fake_embed_chunks)

    source = await _create_source(session, user, "Changing Notes")
    first_job = await create_queued_ingestion_job(user, [source.id], session)
    first_response = await client.post(
        f"/api/ingestion/jobs/{first_job.id}/run",
        json={"sources": [{"source_id": str(source.id), "content": "Original text."}]},
    )
    assert first_response.status_code == 200

    second_job = await create_queued_ingestion_job(user, [source.id], session)
    second_response = await client.post(
        f"/api/ingestion/jobs/{second_job.id}/run",
        json={"sources": [{"source_id": str(source.id), "content": "Updated replacement text."}]},
    )

    assert second_response.status_code == 200
    chunks = (
        (await session.execute(select(SourceChunk).where(SourceChunk.source_id == source.id)))
        .scalars()
        .all()
    )
    assert len(chunks) == 1
    assert chunks[0].content == "Updated replacement text."
    assert source.citation_label == "Changing Notes Citation"


@pytest.mark.asyncio
async def test_run_ingestion_job_marks_blank_content_failed(source_import_client, monkeypatch):
    client, session, user, _ = source_import_client
    monkeypatch.setattr("app.services.source_imports.embed_chunks", _fake_embed_chunks)

    source = await _create_source(session, user, "Blank Notes")
    job = await create_queued_ingestion_job(user, [source.id], session)

    response = await client.post(
        f"/api/ingestion/jobs/{job.id}/run",
        json={"sources": [{"source_id": str(source.id), "content": "   "}]},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "failed"
    assert data["imported_source_count"] == 0
    assert "No importable text found" in data["error_message"]

    await session.refresh(source)
    assert source.status == SourceStatus.FAILED
    assert source.import_error == "No importable text found"


@pytest.mark.asyncio
async def test_run_ingestion_job_rejects_mismatched_source_batch(source_import_client):
    client, session, user, _ = source_import_client
    source = await _create_source(session, user, "Batch Notes")
    other_source = await _create_source(session, user, "Other Batch Notes")
    job = await create_queued_ingestion_job(user, [source.id], session)

    response = await client.post(
        f"/api/ingestion/jobs/{job.id}/run",
        json={"sources": [{"source_id": str(other_source.id), "content": "Wrong source."}]},
    )

    assert response.status_code == 409
    assert response.json()["error"] == "ingestion_job_state_conflict"


@pytest.mark.asyncio
async def test_source_chunks_are_retrieved_and_user_scoped(source_import_session, monkeypatch):
    session, user, other_user = source_import_session
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())

    source = await _create_source(session, user, "Public Notes")
    other_source = await _create_source(session, other_user, "Private Notes")
    source.status = SourceStatus.READY
    other_source.status = SourceStatus.READY
    session.add_all(
        [
            SourceChunk(
                source_id=source.id,
                chunk_index=0,
                citation_ref="Public Notes#1",
                content="This workspace studies limits and continuity.",
                token_count=7,
                embedding=[0.1] * 1536,
            ),
            SourceChunk(
                source_id=other_source.id,
                chunk_index=0,
                citation_ref="Private Notes#1",
                content="Private workspace content.",
                token_count=3,
                embedding=[0.1] * 1536,
            ),
        ]
    )
    await session.commit()

    chunks = await retrieve("limits", user.id, session)

    assert len(chunks) == 1
    assert chunks[0].source_title == "Public Notes"
    assert chunks[0].citation_ref == "Public Notes#1"


async def _query_embedding() -> list[float]:
    return [0.1] * 1536


@pytest.mark.asyncio
async def test_source_chunks_schema_has_required_indexes(source_import_session):
    session, _, _ = source_import_session

    async with session.bind.connect() as connection:
        indexes = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_indexes("source_chunks")
        )
        columns = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_columns("source_chunks")
        )

    column_names = {column["name"] for column in columns}
    assert {
        "source_id",
        "chunk_index",
        "citation_ref",
        "content",
        "token_count",
        "embedding",
    } <= column_names

    index_names = {index["name"] for index in indexes}
    assert {
        "ix_source_chunks_source_id",
        "uq_source_chunks_source_index",
        "ix_source_chunks_embedding",
    } <= index_names
