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
from app.models.ingestion_job import IngestionJob, IngestionJobStatus
from app.models.source import Source
from app.models.user import User
from app.schemas.sources import SourceCreate
from app.services.ingestion_jobs import (
    build_batch_key,
    create_queued_ingestion_job,
    mark_ingestion_job_completed,
    mark_ingestion_job_failed,
    mark_ingestion_job_running,
)
from app.services.sources import create_or_update_source


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def ingestion_job_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        test_emails = ["job-user@example.com", "other-job-user@example.com"]
        await session.execute(delete(User).where(User.email.in_(test_emails)))

        user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Job User",
            email="job-user@example.com",
            password_hash=None,
            encrypted_access_token=None,
            encrypted_refresh_token=None,
        )
        other_user = User(
            id=uuid.uuid4(),
            canvas_user_id=None,
            name="Other Job User",
            email="other-job-user@example.com",
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
async def ingestion_job_client(
    ingestion_job_session: tuple[AsyncSession, User, User],
) -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User], None]:
    session, user, other_user = ingestion_job_session

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
        ),
        session,
    )


@pytest.mark.asyncio
async def test_create_ingestion_job_for_owned_sources(ingestion_job_client):
    client, session, user, _ = ingestion_job_client
    source = await _create_source(session, user, "Owned Notes")

    response = await client.post(
        "/api/ingestion/jobs",
        json={"source_ids": [str(source.id)]},
    )

    assert response.status_code == 201
    data = response.json()
    assert data["user_id"] == str(user.id)
    assert data["status"] == "queued"
    assert data["source_ids"] == [str(source.id)]
    assert data["batch_key"] == str(source.id)
    assert data["source_count"] == 1
    assert data["imported_source_count"] == 0
    assert data["chunk_count"] == 0


@pytest.mark.asyncio
async def test_create_ingestion_job_rejects_other_users_source(ingestion_job_client):
    client, session, _, other_user = ingestion_job_client
    source = await _create_source(session, other_user, "Private Notes")

    response = await client.post(
        "/api/ingestion/jobs",
        json={"source_ids": [str(source.id)]},
    )

    assert response.status_code == 404
    assert response.json()["error"] == "not_found"


@pytest.mark.asyncio
async def test_list_and_get_ingestion_jobs_are_user_scoped(ingestion_job_client):
    client, session, user, other_user = ingestion_job_client
    source = await _create_source(session, user, "Visible Notes")
    other_source = await _create_source(session, other_user, "Hidden Notes")
    job = await create_queued_ingestion_job(user, [source.id], session)
    other_job = await create_queued_ingestion_job(other_user, [other_source.id], session)

    response = await client.get("/api/ingestion/jobs")
    assert response.status_code == 200
    assert [item["id"] for item in response.json()] == [str(job.id)]

    response = await client.get("/api/ingestion/jobs", params={"status": "queued"})
    assert response.status_code == 200
    assert [item["id"] for item in response.json()] == [str(job.id)]

    response = await client.get(f"/api/ingestion/jobs/{job.id}")
    assert response.status_code == 200
    assert response.json()["id"] == str(job.id)

    response = await client.get(f"/api/ingestion/jobs/{other_job.id}")
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_duplicate_active_job_conflict_and_retry_after_terminal_status(
    ingestion_job_client,
):
    client, session, user, _ = ingestion_job_client
    first_source = await _create_source(session, user, "First Notes")
    second_source = await _create_source(session, user, "Second Notes")
    source_ids = [second_source.id, first_source.id]
    job = await create_queued_ingestion_job(user, source_ids, session)

    response = await client.post(
        "/api/ingestion/jobs",
        json={"source_ids": [str(first_source.id), str(second_source.id)]},
    )
    assert response.status_code == 409
    assert response.json()["error"] == "ingestion_job_conflict"
    assert str(job.id) in response.json()["detail"]

    await mark_ingestion_job_completed(job, imported_source_count=2, chunk_count=5, db=session)

    response = await client.post(
        "/api/ingestion/jobs",
        json={"source_ids": [str(first_source.id), str(second_source.id)]},
    )
    assert response.status_code == 201
    assert response.json()["batch_key"] == build_batch_key(source_ids)


@pytest.mark.asyncio
async def test_ingestion_job_lifecycle_transitions(ingestion_job_session):
    session, user, _ = ingestion_job_session
    source = await _create_source(session, user, "Lifecycle Notes")
    job = await create_queued_ingestion_job(user, [source.id], session)

    running = await mark_ingestion_job_running(job, session)
    assert running.status == IngestionJobStatus.RUNNING
    assert running.started_at is not None

    completed = await mark_ingestion_job_completed(
        running,
        imported_source_count=1,
        chunk_count=3,
        db=session,
    )
    assert completed.status == IngestionJobStatus.COMPLETED
    assert completed.imported_source_count == 1
    assert completed.chunk_count == 3
    assert completed.completed_at is not None

    retry_job = await create_queued_ingestion_job(user, [source.id], session)
    failed = await mark_ingestion_job_failed(retry_job, " Parser failed ", session)
    assert failed.status == IngestionJobStatus.FAILED
    assert failed.error_message == "Parser failed"
    assert failed.completed_at is not None


@pytest.mark.asyncio
async def test_ingestion_jobs_schema_has_required_indexes(ingestion_job_session):
    session, _, _ = ingestion_job_session

    async with session.bind.connect() as connection:
        indexes = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_indexes("ingestion_jobs")
        )
        columns = await connection.run_sync(
            lambda sync_conn: inspect(sync_conn).get_columns("ingestion_jobs")
        )

    column_names = {column["name"] for column in columns}
    assert {
        "user_id",
        "status",
        "source_ids",
        "batch_key",
        "source_count",
        "imported_source_count",
        "chunk_count",
        "error_message",
        "started_at",
        "completed_at",
    } <= column_names

    index_names = {index["name"] for index in indexes}
    assert {
        "ix_ingestion_jobs_user_status",
        "ix_ingestion_jobs_user_created_at",
        "ix_ingestion_jobs_user_batch_key",
        "uq_ingestion_jobs_active_batch",
    } <= index_names
