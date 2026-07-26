import asyncio
import uuid
from collections.abc import AsyncGenerator
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, func, select, text, update
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.exceptions import WikiBaseError
from app.main import app
from app.models.processing import (
    ProcessingEnqueueRequest,
    ProcessingEvent,
    ProcessingPolicy,
    ProcessingRun,
    ProcessingStage,
    SourceVersion,
)
from app.models.settings import InAppNotification
from app.models.source import Source, SourceKind, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.schemas.m3 import StudyOutputGenerateRequest
from app.services.curriculum import _source_chunks_fingerprint
from app.services.curriculum_coverage import _chunks_by_source
from app.services.flashcards import _source_candidates
from app.services.processing import (
    cancel_run,
    claim_stage,
    enqueue_source_version,
    execute_claimed_stage,
    get_run,
    heartbeat_stage,
    retry_run,
)
from app.services.retrieval import retrieve
from app.services.search import search_workspace
from app.services.study_outputs import _evidence_for_request
from app.services.wiki import _load_sources, build_source_page_draft


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
        await session.execute(text("SELECT 1 FROM processing_runs LIMIT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"processing database is unavailable or not migrated: {exc}")


@pytest.fixture
async def processing_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        emails = ["processing-user@example.com", "processing-other@example.com"]
        await session.execute(delete(User).where(User.email.in_(emails)))
        user = User(id=uuid.uuid4(), name="Processing User", email=emails[0])
        other = User(id=uuid.uuid4(), name="Other User", email=emails[1])
        session.add_all([user, other])
        await session.commit()
        user_id, other_id = user.id, other.id
        try:
            yield session, user, other
        finally:
            await session.rollback()
            await session.execute(delete(User).where(User.id.in_([user_id, other_id])))
            await session.commit()
    await engine.dispose()


async def _source(session: AsyncSession, user: User, title: str = "Pipeline notes") -> Source:
    source = Source(
        user_id=user.id,
        source_type=SourceKind.PLAIN_TEXT,
        origin="upload",
        title=title,
        citation_label=title,
        status=SourceStatus.PENDING,
    )
    session.add(source)
    await session.commit()
    return source


async def _enqueue(
    session: AsyncSession, user: User, source: Source, content: str
) -> ProcessingRun:
    return await enqueue_source_version(
        user,
        source,
        filename="notes.txt",
        content=content,
        content_base64=None,
        source_url=None,
        db=session,
    )


async def _finish_run(run_id: uuid.UUID) -> ProcessingRun:
    for position in range(5):
        worker = f"test-worker-{position}"
        async with async_session_factory() as session:
            stage = await claim_stage(session, worker)
            assert stage is not None
            assert stage.run_id == run_id
            run = await execute_claimed_stage(session, stage.id, worker)
            assert run is not None
    async with async_session_factory() as session:
        run = await session.scalar(
            select(ProcessingRun).where(ProcessingRun.id == run_id).options()
        )
        assert run is not None
        return run


@pytest.mark.asyncio
async def test_immediately_enqueued_stage_uses_database_time_for_claim(
    processing_session, monkeypatch
):
    session, user, _ = processing_session
    source = await _source(session, user, "Immediate claim notes")
    run = await _enqueue(session, user, source, "An immediately queued stage is claimable.")
    stage = await session.scalar(
        select(ProcessingStage).where(
            ProcessingStage.run_id == run.id,
            ProcessingStage.status == "queued",
        )
    )
    assert stage is not None
    database_now = await session.scalar(select(func.clock_timestamp()))
    assert stage.available_at <= database_now
    monkeypatch.setattr(
        "app.services.processing._now",
        lambda: stage.available_at - timedelta(seconds=1),
    )

    async with async_session_factory() as blocker:
        await blocker.execute(
            select(ProcessingStage).where(ProcessingStage.id != stage.id).with_for_update()
        )
        claimed = await claim_stage(session, "immediate-worker")
        await blocker.rollback()

    assert claimed is not None
    assert claimed.id == stage.id
    assert claimed.lease_owner == "immediate-worker"
    assert claimed.lease_token == 1
    assert claimed.lease_expires_at > database_now


@pytest.mark.asyncio
async def test_pipeline_is_durable_idempotent_and_reaches_ready(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user)
    content = "A durable pipeline preserves cited evidence across worker restarts and retries."
    run = await _enqueue(session, user, source, content)
    replay = await _enqueue(session, user, source, content)

    assert replay.id == run.id
    run_id, source_id, user_id = run.id, source.id, user.id
    await _finish_run(run_id)
    await session.rollback()
    stored_user = await session.get(User, user_id)
    assert stored_user is not None
    stored = await get_run(stored_user, run_id, session)
    chunks = await session.scalar(
        select(func.count(SourceChunk.id)).where(SourceChunk.source_id == source_id)
    )
    versions = await session.scalar(
        select(func.count(SourceVersion.id)).where(SourceVersion.source_id == source_id)
    )

    assert stored.status == "ready"
    assert [stage.status for stage in stored.stages] == [
        "succeeded",
        "skipped",
        "skipped",
        "succeeded",
        "succeeded",
    ]
    assert chunks == 1
    assert versions == 1
    assert any(event.event_type == "run_ready" for event in stored.events)


@pytest.mark.asyncio
async def test_concurrent_distinct_keys_coalesce_one_source_version_run(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user, "Coalesced notes")
    user_id, source_id = user.id, source.id
    content = "Concurrent intake of identical source content must create one durable run."

    async def enqueue(key: str):
        async with async_session_factory() as concurrent_session:
            stored_user = await concurrent_session.get(User, user_id)
            stored_source = await concurrent_session.get(Source, source_id)
            assert stored_user is not None and stored_source is not None
            return await enqueue_source_version(
                stored_user,
                stored_source,
                filename="coalesced.txt",
                content=content,
                content_base64=None,
                source_url=None,
                db=concurrent_session,
                idempotency_key=key,
            )

    first, second = await asyncio.gather(
        enqueue("coalesce-request-one"),
        enqueue("coalesce-request-two"),
    )
    await session.rollback()
    run_count = await session.scalar(
        select(func.count(ProcessingRun.id)).where(ProcessingRun.source_id == source_id)
    )
    version_count = await session.scalar(
        select(func.count(SourceVersion.id)).where(SourceVersion.source_id == source_id)
    )
    stage_count = await session.scalar(
        select(func.count(ProcessingStage.id)).where(ProcessingStage.run_id == first.id)
    )
    request_count = await session.scalar(
        select(func.count(ProcessingEnqueueRequest.id)).where(
            ProcessingEnqueueRequest.run_id == first.id
        )
    )

    assert first.id == second.id
    assert run_count == version_count == 1
    assert stage_count == 5
    assert request_count == 2


@pytest.mark.asyncio
async def test_completed_trigger_api_replays_run_across_distinct_keys(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user, "Completed replay notes")
    run = await _enqueue(session, user, source, "Completed content is replayed, not rebuilt.")
    user_id, source_id = user.id, source.id
    await _finish_run(run.id)

    async def current_user():
        async with async_session_factory() as lookup:
            stored = await lookup.get(User, user_id)
            assert stored is not None
            return stored

    async def current_db():
        async with async_session_factory() as request_session:
            yield request_session

    app.dependency_overrides[get_current_user] = current_user
    app.dependency_overrides[get_db] = current_db
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            first, second = await asyncio.gather(
                client.post(
                    "/api/processing/trigger",
                    json={"source_id": str(source_id)},
                    headers={"Idempotency-Key": "completed-replay-one"},
                ),
                client.post(
                    "/api/processing/trigger",
                    json={"source_id": str(source_id)},
                    headers={"Idempotency-Key": "completed-replay-two"},
                ),
            )
    finally:
        app.dependency_overrides.clear()

    assert first.status_code == second.status_code == 202
    assert first.json()["id"] == second.json()["id"] == str(run.id)
    assert first.json()["status"] == second.json()["status"] == "ready"
    async with async_session_factory() as check:
        assert (
            await check.scalar(
                select(func.count(ProcessingRun.id)).where(ProcessingRun.source_id == source_id)
            )
            == 1
        )
        assert (
            await check.scalar(
                select(func.count(ProcessingStage.id)).where(ProcessingStage.run_id == run.id)
            )
            == 5
        )


@pytest.mark.asyncio
async def test_cancelled_version_requires_explicit_retry(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user, "Cancelled replay notes")
    run = await enqueue_source_version(
        user,
        source,
        filename="cancelled.txt",
        content="Cancelled content remains terminal until an explicit retry.",
        content_base64=None,
        source_url=None,
        db=session,
        idempotency_key="cancelled-original-key",
    )
    cancelled = await cancel_run(user, run.id, session)
    replay = await enqueue_source_version(
        user,
        source,
        filename="cancelled.txt",
        content="Cancelled content remains terminal until an explicit retry.",
        content_base64=None,
        source_url=None,
        db=session,
        idempotency_key="cancelled-distinct-key",
    )

    assert replay.id == cancelled.id
    assert replay.status == "cancelled"
    retried = await retry_run(user, replay.id, session)
    assert retried.id == cancelled.id
    assert retried.status == "queued"
    assert retried.cancelled_at is None


@pytest.mark.asyncio
async def test_same_key_still_conflicts_for_different_source_content(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user, "Conflict notes")
    key = "same-request-hash-key"
    await enqueue_source_version(
        user,
        source,
        filename="conflict.txt",
        content="First request body",
        content_base64=None,
        source_url=None,
        db=session,
        idempotency_key=key,
    )

    with pytest.raises(WikiBaseError) as exc_info:
        await enqueue_source_version(
            user,
            source,
            filename="conflict.txt",
            content="Different request body",
            content_base64=None,
            source_url=None,
            db=session,
            idempotency_key=key,
        )
    assert exc_info.value.status_code == 409
    assert exc_info.value.error == "idempotency_conflict"


@pytest.mark.asyncio
async def test_failed_replacement_preserves_last_valid_chunks(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user, "Replacement notes")
    ready_run = await _enqueue(
        session,
        user,
        source,
        "The last valid source version remains available if its replacement cannot be parsed.",
    )
    source_id, user_id = source.id, user.id
    await _finish_run(ready_run.id)

    await session.rollback()
    stored_user = await session.get(User, user_id)
    stored_source = await session.get(Source, source_id)
    assert stored_user is not None and stored_source is not None
    old_version_id = stored_source.current_version_id
    replacement = await _enqueue(session, stored_user, stored_source, "")
    stage = await claim_stage(session, "replacement-failure-worker")
    assert stage is not None and stage.run_id == replacement.id
    stage.max_attempts = 1
    await session.commit()
    failed = await execute_claimed_stage(session, stage.id, "replacement-failure-worker")

    assert failed is not None and failed.status == "failed"
    await session.refresh(stored_user)
    await session.refresh(stored_source)
    replay = await enqueue_source_version(
        stored_user,
        stored_source,
        filename="notes.txt",
        content="",
        content_base64=None,
        source_url=None,
        db=session,
        idempotency_key="failed-replay-distinct-key",
    )
    assert replay.id == failed.id
    assert replay.status == "failed"
    await session.refresh(stored_source)
    assert stored_source.status == SourceStatus.READY
    assert stored_source.current_version_id == old_version_id
    chunks = await session.scalar(
        select(func.count(SourceChunk.id)).where(SourceChunk.source_id == source_id)
    )
    assert chunks == 1


@pytest.mark.asyncio
async def test_local_flashcard_generation_does_not_require_provider(processing_session):
    session, user, _ = processing_session
    policy = ProcessingPolicy(
        user_id=user.id,
        process_sources=True,
        compile_wiki=True,
        flashcard_mode="draft",
        require_deck_review=True,
    )
    session.add(policy)
    source = await _source(session, user, "Provider notes")
    run = await _enqueue(
        session,
        user,
        source,
        "Deterministic indexing completes before optional provider-backed draft generation.",
    )

    run_id, source_id = run.id, source.id
    for position in range(5):
        worker = f"provider-worker-{position}"
        stage = await claim_stage(session, worker)
        assert stage is not None
        result = await execute_claimed_stage(session, stage.id, worker)
        assert result is not None

    await session.rollback()
    stored = await session.scalar(select(ProcessingRun).where(ProcessingRun.id == run_id))
    stored_source = await session.get(Source, source_id)
    assert stored is not None and stored.status == "ready"
    assert stored.pause_reason is None
    assert stored_source is not None and stored_source.status == SourceStatus.READY


@pytest.mark.asyncio
async def test_expired_lease_is_reclaimed_and_cancellation_is_terminal(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user, "Lease notes")
    run = await _enqueue(
        session,
        user,
        source,
        "Expired worker leases are safely reclaimed without losing durable state.",
    )
    stage = await claim_stage(session, "dead-worker")
    assert stage is not None
    stage.lease_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await session.commit()

    reclaimed = await claim_stage(session, "replacement-worker")
    assert reclaimed is not None
    assert reclaimed.id == stage.id
    assert reclaimed.attempt_count == 2
    cancelled = await cancel_run(user, run.id, session)

    assert cancelled.status == "cancelled"
    assert all(item.status in {"cancelled", "succeeded", "skipped"} for item in cancelled.stages)


@pytest.mark.asyncio
async def test_expired_lease_at_max_attempts_is_failed_once_by_concurrent_recoverers(
    processing_session,
):
    session, user, _ = processing_session
    source = await _source(session, user, "Exhausted lease notes")
    run = await _enqueue(
        session,
        user,
        source,
        "An expired final attempt must terminate rather than execute forever.",
    )
    stage = await claim_stage(session, "dead-final-worker")
    assert stage is not None
    stage.max_attempts = stage.attempt_count
    stage.lease_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await session.commit()

    async def recover(worker_id: str):
        async with async_session_factory() as recovery_session:
            return await claim_stage(recovery_session, worker_id)

    recovered = await asyncio.gather(recover("recoverer-one"), recover("recoverer-two"))
    assert recovered == [None, None]

    await session.rollback()
    stored_stage = await session.get(ProcessingStage, stage.id)
    stored_run = await session.get(ProcessingRun, run.id)
    assert stored_stage is not None and stored_run is not None
    await session.refresh(stored_stage)
    await session.refresh(stored_run)
    event_count = await session.scalar(
        select(func.count(ProcessingEvent.id)).where(
            ProcessingEvent.run_id == run.id,
            ProcessingEvent.dedupe_key == "stage:parse_index:failed",
        )
    )
    notification_count = await session.scalar(
        select(func.count(InAppNotification.id)).where(
            InAppNotification.user_id == user.id,
            InAppNotification.dedupe_key == f"processing-failed:{run.id}:parse_index",
        )
    )

    assert stored_stage is not None and stored_stage.status == "failed"
    assert stored_stage.attempt_count == stored_stage.max_attempts == 1
    assert stored_run is not None and stored_run.status == "failed"
    assert event_count == 1
    assert notification_count == 1


@pytest.mark.asyncio
async def test_processing_status_api_is_user_scoped(processing_session):
    session, user, other = processing_session
    source = await _source(session, other, "Private notes")
    run = await _enqueue(
        session,
        other,
        source,
        "Processing status and source evidence remain private to their owning user.",
    )

    async def current_user():
        return user

    async def current_db():
        yield session

    app.dependency_overrides[get_current_user] = current_user
    app.dependency_overrides[get_db] = current_db
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get(f"/api/processing/runs/{run.id}")
            listing = await client.get("/api/processing/runs")
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 404
    assert listing.status_code == 200
    assert all(item["id"] != str(run.id) for item in listing.json())


@pytest.mark.asyncio
async def test_processing_events_are_deduplicated(processing_session):
    session, user, _ = processing_session
    source = await _source(session, user, "Event notes")
    run = await _enqueue(
        session,
        user,
        source,
        "Replayed source intake creates one durable queue and one queued activity event.",
    )
    await _enqueue(
        session,
        user,
        source,
        "Replayed source intake creates one durable queue and one queued activity event.",
    )

    event_count = await session.scalar(
        select(func.count(ProcessingEvent.id)).where(
            ProcessingEvent.run_id == run.id,
            ProcessingEvent.dedupe_key == "run:queued",
        )
    )
    stage_count = await session.scalar(
        select(func.count(ProcessingStage.id)).where(ProcessingStage.run_id == run.id)
    )
    assert event_count == 1
    assert stage_count == 5


@pytest.mark.asyncio
async def test_interleaved_versions_retain_chunks_and_newest_wins(processing_session, monkeypatch):
    session, user, _ = processing_session
    source = await _source(session, user, "Concurrent notes")
    first = await _enqueue(session, user, source, "Version one evidence remains retained.")
    second = await _enqueue(session, user, source, "Version two evidence becomes current.")

    first_stage = await claim_stage(session, "first-worker")
    second_stage = await claim_stage(session, "second-worker")
    assert first_stage is not None and first_stage.run_id == first.id
    assert second_stage is not None and second_stage.run_id == second.id

    await execute_claimed_stage(session, second_stage.id, "second-worker", second_stage.lease_token)
    await execute_claimed_stage(session, first_stage.id, "first-worker", first_stage.lease_token)
    await session.refresh(source)
    chunks = list(
        (
            await session.execute(
                select(SourceChunk)
                .where(SourceChunk.source_id == source.id)
                .order_by(SourceChunk.source_version_id, SourceChunk.chunk_index)
            )
        ).scalars()
    )

    assert source.current_version_id == second.source_version_id
    assert {chunk.source_version_id for chunk in chunks} == {
        first.source_version_id,
        second.source_version_id,
    }
    assert {chunk.content for chunk in chunks} == {
        "Version one evidence remains retained.",
        "Version two evidence becomes current.",
    }

    embedding = [1.0] + [0.0] * 1535
    for chunk in chunks:
        chunk.embedding = embedding
    await session.flush()

    async def embed_current(_query: str):
        return embedding

    monkeypatch.setattr("app.services.retrieval.embed_query", embed_current)
    monkeypatch.setattr("app.services.search.embed_query", embed_current)
    retrieved = await retrieve("version", user.id, session)
    searched = await search_workspace("version", user.id, session)
    flashcard_candidates, _ = await _source_candidates(user, session, [source.id], None)
    evidence, _, _, _ = await _evidence_for_request(
        user,
        StudyOutputGenerateRequest(source_ids=[source.id]),
        session,
    )
    coverage_chunks = (await _chunks_by_source(session, [source.id]))[source.id]
    curriculum_chunks, _, _, curriculum_count = await _source_chunks_fingerprint(session, source.id)
    wiki_sources = await _load_sources(user, [source.id], session)
    wiki_draft = build_source_page_draft(wiki_sources[0], "concurrent-notes")

    assert {item.content for item in retrieved if item.source_id == str(source.id)} == {
        "Version two evidence becomes current."
    }
    assert {item.snippet for item in searched if item.source_id == source.id} == {
        "Version two evidence becomes current."
    }
    assert {item.content for item in flashcard_candidates} == {
        "Version two evidence becomes current."
    }
    assert {item.text for item in evidence} == {"Version two evidence becomes current."}
    assert {item.content for item in coverage_chunks} == {"Version two evidence becomes current."}
    assert {item.content for item in curriculum_chunks} == {"Version two evidence becomes current."}
    assert curriculum_count == 1
    assert "Version two evidence becomes current." in wiki_draft.sections[0]
    assert "Version one evidence remains retained." not in wiki_draft.sections[0]


@pytest.mark.asyncio
async def test_heartbeat_is_fenced_and_lease_theft_rolls_back_outputs(
    processing_session, monkeypatch
):
    session, user, _ = processing_session
    source = await _source(session, user, "Fenced notes")
    run = await _enqueue(session, user, source, "Fenced lease evidence.")
    stage = await claim_stage(session, "original-worker")
    assert stage is not None
    old_expiry = stage.lease_expires_at
    monkeypatch.setattr(
        "app.services.processing._now",
        lambda: old_expiry - timedelta(seconds=60),
    )
    assert await heartbeat_stage(session, stage.id, "original-worker", stage.lease_token)
    await session.refresh(stage)
    assert old_expiry is not None and stage.lease_expires_at > old_expiry
    assert not await heartbeat_stage(session, stage.id, "original-worker", stage.lease_token + 1)

    async def steal_after_nested_operation(claimed_run, _stage, db):
        stored_source = await db.get(Source, claimed_run.source_id)
        assert stored_source is not None
        stored_source.title = "unfenced output"
        async with async_session_factory() as thief:
            await thief.execute(
                update(ProcessingStage)
                .where(ProcessingStage.id == stage.id)
                .values(lease_owner="thief", lease_token=stage.lease_token + 1)
            )
            await thief.commit()
        return {"nested": "output"}

    monkeypatch.setattr("app.services.processing._execute_stage", steal_after_nested_operation)
    source_id, run_id = source.id, run.id
    result = await execute_claimed_stage(session, stage.id, "original-worker", stage.lease_token)
    await session.rollback()
    stored_source = await session.get(Source, source_id)
    stored_run = await session.get(ProcessingRun, run_id)

    assert result is None
    assert stored_source is not None and stored_source.title == "Fenced notes"
    assert stored_run is not None and stored_run.status == "running"
