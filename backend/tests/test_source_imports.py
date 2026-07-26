import base64
import uuid
from collections.abc import AsyncGenerator
from io import BytesIO
from types import SimpleNamespace

import pytest
from httpx import ASGITransport, AsyncClient
from PIL import Image
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
from app.services.processing import claim_stage, execute_claimed_stage
from app.services.retrieval import retrieve
from app.services.sources import create_or_update_source


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError) as exc:
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


async def _create_typed_source(
    session: AsyncSession,
    user: User,
    title: str,
    source_type: str,
    source_url: str = "",
) -> Source:
    return await create_or_update_source(
        user,
        SourceCreate(
            source_type=source_type,
            origin="test",
            external_id=f"{source_type}-{title.lower().replace(' ', '-')}-{uuid.uuid4()}",
            title=title,
            source_url=source_url,
            citation_label=f"{title} Citation",
        ),
        session,
    )


async def _fake_embed_chunks(chunks: list[SourceChunk], db: AsyncSession) -> None:
    for chunk in chunks:
        chunk.embedding = [0.1] * 1536
    await db.flush()


@pytest.mark.asyncio
async def test_unified_source_intake_imports_pasted_text_and_deduplicates(
    source_import_client,
    monkeypatch,
):
    client, session, _, _ = source_import_client
    monkeypatch.setattr("app.services.source_imports.embed_chunks", _fake_embed_chunks)
    payload = {
        "mode": "paste",
        "title": "Recursion notes",
        "course_context": "CS2030S",
        "source_type": "plain_text",
        "content": "A recursive function needs a base case and a smaller subproblem.",
    }

    first = await client.post("/api/sources/import", json=payload)
    second = await client.post("/api/sources/import", json=payload)

    assert first.status_code == 201
    assert first.json()["import_status"] == "queued"
    assert first.json()["duplicate"] is False
    assert second.status_code == 201
    assert second.json()["duplicate"] is True
    assert second.json()["source"]["id"] == first.json()["source"]["id"]
    source_id = uuid.UUID(first.json()["source"]["id"])
    chunks = (
        (await session.execute(select(SourceChunk).where(SourceChunk.source_id == source_id)))
        .scalars()
        .all()
    )
    assert chunks == []


@pytest.mark.asyncio
async def test_unified_source_intake_idempotency_conflict_preserves_sources(
    source_import_client,
):
    client, session, user, _ = source_import_client
    user_id = user.id
    idempotency_key = "source-intake-key-0001"
    first_payload = {
        "mode": "paste",
        "title": "Original recursion notes",
        "course_context": "CS2030S",
        "source_type": "plain_text",
        "content": "A recursive function needs a base case.",
    }

    first = await client.post(
        "/api/sources/import",
        json=first_payload,
        headers={"Idempotency-Key": idempotency_key},
    )
    assert first.status_code == 201
    sources_before = (
        (await session.execute(select(Source).where(Source.user_id == user_id))).scalars().all()
    )
    assert len(sources_before) == 1
    metadata_before = (
        sources_before[0].title,
        sources_before[0].citation_label,
        sources_before[0].course_context,
        sources_before[0].status,
    )

    conflict = await client.post(
        "/api/sources/import",
        json={
            **first_payload,
            "title": "Conflicting metadata",
            "course_context": "Changed course",
            "content": "Different upload content must conflict.",
        },
        headers={"Idempotency-Key": idempotency_key},
    )

    assert conflict.status_code == 409
    assert conflict.json()["error"] == "idempotency_conflict"
    sources_after = (
        (await session.execute(select(Source).where(Source.user_id == user_id))).scalars().all()
    )
    assert len(sources_after) == 1
    assert (
        sources_after[0].title,
        sources_after[0].citation_label,
        sources_after[0].course_context,
        sources_after[0].status,
    ) == metadata_before


@pytest.mark.asyncio
async def test_completed_unified_source_intake_replay_preserves_ready_source(
    source_import_client,
    monkeypatch,
):
    client, session, user, _ = source_import_client
    monkeypatch.setattr("app.services.processing.embed_chunks", _fake_embed_chunks)
    monkeypatch.setattr(
        "app.services.processing.get_settings",
        lambda: SimpleNamespace(openai_api_key="test"),
    )
    monkeypatch.setattr("app.services.retrieval.embed_query", lambda _: _query_embedding())
    payload = {
        "mode": "paste",
        "title": "Replay-safe notes",
        "course_context": "CS2030S",
        "source_type": "plain_text",
        "content": "A completed idempotent import keeps its current evidence retrievable.",
    }

    first = await client.post("/api/sources/import", json=payload)
    assert first.status_code == 201
    first_body = first.json()
    run_id = uuid.UUID(first_body["job_id"])
    for position in range(5):
        worker_id = f"intake-replay-worker-{position}"
        stage = await claim_stage(session, worker_id)
        assert stage is not None and stage.run_id == run_id
        await execute_claimed_stage(session, stage.id, worker_id)

    replay = await client.post("/api/sources/import", json=payload)

    assert replay.status_code == 201
    replay_body = replay.json()
    assert replay_body["job_id"] == first_body["job_id"]
    assert replay_body["import_status"] == "completed"
    assert replay_body["duplicate"] is True
    assert replay_body["source"]["status"] == "ready"
    source = await session.get(Source, uuid.UUID(first_body["source"]["id"]))
    assert source is not None and source.current_version_id is not None
    current_chunks = (
        (
            await session.execute(
                select(SourceChunk).where(
                    SourceChunk.source_id == source.id,
                    SourceChunk.source_version_id == source.current_version_id,
                )
            )
        )
        .scalars()
        .all()
    )
    assert len(current_chunks) == 1
    retrieved = await retrieve("current evidence", user.id, session)
    assert [chunk.content for chunk in retrieved] == [current_chunks[0].content]


@pytest.mark.asyncio
async def test_unified_source_intake_ocr_imports_png(source_import_client, monkeypatch):
    client, session, _, _ = source_import_client
    monkeypatch.setattr("app.services.source_imports.embed_chunks", _fake_embed_chunks)
    monkeypatch.setattr(
        "app.services.source_parsers.pytesseract.image_to_string",
        lambda image, **kwargs: "A monad sequences computations while preserving context.",
    )
    image = BytesIO()
    Image.new("RGB", (160, 90), "white").save(image, format="PNG")

    response = await client.post(
        "/api/sources/import",
        json={
            "mode": "upload",
            "title": "Functional programming note",
            "course_context": "CS2030S",
            "source_type": "image",
            "filename": "note.png",
            "content_base64": base64.b64encode(image.getvalue()).decode(),
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["import_status"] == "queued"
    assert body["source"]["source_type"] == "image"
    source_id = uuid.UUID(body["source"]["id"])
    chunks = (
        (await session.execute(select(SourceChunk).where(SourceChunk.source_id == source_id)))
        .scalars()
        .all()
    )
    assert chunks == []


@pytest.mark.asyncio
async def test_unified_source_intake_saves_links_as_truthful_metadata(source_import_client):
    client, session, _, _ = source_import_client
    response = await client.post(
        "/api/sources/import",
        json={
            "mode": "link",
            "title": "Module reference",
            "source_type": "link",
            "source_url": "https://example.com/reference",
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["import_status"] == "saved"
    assert body["job_id"] is None
    assert body["source"]["status"] == "pending"
    source_id = uuid.UUID(body["source"]["id"])
    assert (
        await session.execute(select(SourceChunk).where(SourceChunk.source_id == source_id))
    ).scalars().all() == []


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
async def test_parse_run_imports_markdown_sections_with_locations(
    source_import_client,
    monkeypatch,
):
    client, session, user, _ = source_import_client
    monkeypatch.setattr("app.services.source_imports.embed_chunks", _fake_embed_chunks)

    source = await _create_typed_source(session, user, "Markdown Notes", "markdown")
    job = await create_queued_ingestion_job(user, [source.id], session)

    response = await client.post(
        f"/api/ingestion/jobs/{job.id}/parse-run",
        json={
            "sources": [
                {
                    "source_id": str(source.id),
                    "filename": "notes.md",
                    "content": (
                        "# Limits\nLimits describe behavior.\n\n## Continuity\nMatches values."
                    ),
                }
            ]
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "completed"
    chunks = (
        (
            await session.execute(
                select(SourceChunk)
                .where(SourceChunk.source_id == source.id)
                .order_by(SourceChunk.chunk_index)
            )
        )
        .scalars()
        .all()
    )
    assert [chunk.location_label for chunk in chunks] == ["Limits", "Limits > Continuity"]
    assert chunks[0].citation_ref == "Markdown Notes Citation: Limits"
    assert chunks[1].citation_ref == "Markdown Notes Citation: Limits > Continuity"


@pytest.mark.asyncio
async def test_parse_run_imports_plain_text(source_import_client, monkeypatch):
    client, session, user, _ = source_import_client
    monkeypatch.setattr("app.services.source_imports.embed_chunks", _fake_embed_chunks)

    source = await _create_typed_source(session, user, "Text Notes", "plain_text")
    job = await create_queued_ingestion_job(user, [source.id], session)

    response = await client.post(
        f"/api/ingestion/jobs/{job.id}/parse-run",
        json={
            "sources": [
                {
                    "source_id": str(source.id),
                    "filename": "notes.txt",
                    "content": "First line\r\n second line\n\nThird line",
                }
            ]
        },
    )

    assert response.status_code == 200
    assert response.json()["chunk_count"] == 1
    chunk = (
        await session.execute(select(SourceChunk).where(SourceChunk.source_id == source.id))
    ).scalar_one()
    assert chunk.content == "First line second line\n\nThird line"


@pytest.mark.asyncio
async def test_parse_run_does_not_publish_metadata_only_sources(source_import_client):
    client, session, user, _ = source_import_client
    link = await _create_typed_source(
        session,
        user,
        "Reference Link",
        "link",
        source_url="https://example.com/reading",
    )
    repository = await _create_typed_source(
        session,
        user,
        "Reference Repository",
        "repository",
        source_url="https://github.com/example/repo",
    )
    job = await create_queued_ingestion_job(user, [link.id, repository.id], session)

    response = await client.post(
        f"/api/ingestion/jobs/{job.id}/parse-run",
        json={
            "sources": [
                {"source_id": str(link.id), "source_url": link.source_url},
                {"source_id": str(repository.id), "source_url": repository.source_url},
            ]
        },
    )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "failed"
    assert data["imported_source_count"] == 0
    assert data["chunk_count"] == 0
    assert "Metadata-only sources cannot be published" in data["error_message"]

    await session.refresh(link)
    await session.refresh(repository)
    assert link.status == SourceStatus.FAILED
    assert repository.status == SourceStatus.FAILED
    assert (
        await session.execute(
            select(SourceChunk).where(SourceChunk.source_id.in_([link.id, repository.id]))
        )
    ).scalars().all() == []


@pytest.mark.asyncio
async def test_parse_run_marks_parser_errors_failed(source_import_client):
    client, session, user, _ = source_import_client
    source = await _create_typed_source(session, user, "Broken Markdown", "markdown")
    job = await create_queued_ingestion_job(user, [source.id], session)

    response = await client.post(
        f"/api/ingestion/jobs/{job.id}/parse-run",
        json={"sources": [{"source_id": str(source.id), "filename": "broken.md"}]},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "failed"
    assert "Markdown content is required" in data["error_message"]

    await session.refresh(source)
    assert source.status == SourceStatus.FAILED
    assert source.import_error == "Markdown content is required"


@pytest.mark.asyncio
async def test_run_ingestion_job_retains_versioned_chunks(source_import_client, monkeypatch):
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
    await session.refresh(source)
    assert len(chunks) == 2
    assert {chunk.content for chunk in chunks} == {
        "Original text.",
        "Updated replacement text.",
    }
    assert all(chunk.source_version_id is not None for chunk in chunks)
    current_chunks = [
        chunk for chunk in chunks if chunk.source_version_id == source.current_version_id
    ]
    assert len(current_chunks) == 1
    assert current_chunks[0].content == "Updated replacement text."
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
        "source_version_id",
        "fingerprint",
        "chunk_index",
        "citation_ref",
        "location_label",
        "content",
        "token_count",
        "embedding",
    } <= column_names

    index_names = {index["name"] for index in indexes}
    assert {
        "ix_source_chunks_source_id",
        "uq_source_chunks_version_index",
        "ix_source_chunks_embedding",
    } <= index_names
