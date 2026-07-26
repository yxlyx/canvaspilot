import asyncio
import hashlib
import json
import uuid
from datetime import UTC, datetime, timedelta

from pydantic_core import to_jsonable_python
from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.config import get_settings
from app.db.database import async_session_factory
from app.exceptions import NotFoundError, WikiBaseError
from app.models.content import SourceType
from app.models.curriculum import ModuleEnrollment
from app.models.processing import (
    STAGE_NAMES,
    ProcessingCoverageSnapshot,
    ProcessingEnqueueRequest,
    ProcessingEvent,
    ProcessingPolicy,
    ProcessingRun,
    ProcessingStage,
    SourceVersion,
)
from app.models.settings import InAppNotification
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.schemas.flashcards import FlashcardGenerateRequest
from app.schemas.processing import ProcessingPolicyUpdate
from app.schemas.source_imports import SourceImportSection, SourceParseItem
from app.services.curriculum_coverage import coverage_dashboard, generate_proposals
from app.services.embedding import embed_chunks
from app.services.flashcards import generate_flashcard_deck
from app.services.ingestion import ChunkMeta, chunk_text
from app.services.notifications import upsert_notification
from app.services.source_parsers import parse_source_payload
from app.services.wiki import compile_workspace_wiki

LEASE_SECONDS = 60
RETRY_DELAYS = (5, 30, 120, 600)
MAX_ATTEMPTS = {"parse_index": 3, "topic_proposals": 3, "coverage": 3, "wiki": 4, "flashcards": 4}


class ProviderUnavailableError(RuntimeError):
    pass


def _now() -> datetime:
    return datetime.now(UTC)


def _json_compatible(value: object) -> object:
    return to_jsonable_python(value)


def _fingerprint(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _safe_error(exc: Exception) -> str:
    message = " ".join(str(exc).split()) or "Stage failed"
    return message[:1000]


async def get_processing_policy(user_id: uuid.UUID, db: AsyncSession) -> ProcessingPolicy:
    await db.execute(
        insert(ProcessingPolicy)
        .values(user_id=user_id)
        .on_conflict_do_nothing(index_elements=[ProcessingPolicy.user_id])
    )
    policy = await db.get(ProcessingPolicy, user_id)
    if policy is None:
        raise RuntimeError("processing policy insert did not return the stored row")
    return policy


async def update_processing_policy(
    user: User, payload: ProcessingPolicyUpdate, db: AsyncSession
) -> ProcessingPolicy:
    policy = await get_processing_policy(user.id, db)
    for field, value in payload.model_dump(exclude_unset=True).items():
        if value is not None:
            setattr(policy, field, value)
    policy.require_deck_review = True
    if payload.process_sources is False:
        await db.execute(
            update(ProcessingRun)
            .where(
                ProcessingRun.user_id == user.id,
                ProcessingRun.status == "queued",
            )
            .values(status="paused", pause_reason="source_processing_disabled")
        )
        await db.execute(
            update(ProcessingStage)
            .where(
                ProcessingStage.run_id.in_(
                    select(ProcessingRun.id).where(
                        ProcessingRun.user_id == user.id,
                        ProcessingRun.pause_reason == "source_processing_disabled",
                    )
                ),
                ProcessingStage.status == "queued",
            )
            .values(status="paused")
        )
    elif payload.process_sources is True:
        paused_runs = select(ProcessingRun.id).where(
            ProcessingRun.user_id == user.id,
            ProcessingRun.status == "paused",
            ProcessingRun.pause_reason == "source_processing_disabled",
        )
        await db.execute(
            update(ProcessingStage)
            .where(
                ProcessingStage.run_id.in_(paused_runs),
                ProcessingStage.status == "paused",
            )
            .values(status="queued", available_at=_now())
        )
        await db.execute(
            update(ProcessingRun)
            .where(ProcessingRun.id.in_(paused_runs))
            .values(status="queued", pause_reason=None, next_attempt_at=_now())
        )
    await db.commit()
    await db.refresh(policy)
    return policy


def _policy_snapshot(policy: ProcessingPolicy) -> dict:
    return {
        "process_sources": policy.process_sources,
        "map_topics": policy.map_topics,
        "compile_wiki": policy.compile_wiki,
        "flashcard_mode": policy.flashcard_mode,
        "require_deck_review": True,
    }


async def _event(
    db: AsyncSession,
    run: ProcessingRun,
    event_type: str,
    dedupe_key: str,
    *,
    stage: ProcessingStage | None = None,
    payload: dict | None = None,
) -> None:
    await db.execute(
        insert(ProcessingEvent)
        .values(
            run_id=run.id,
            stage_id=stage.id if stage else None,
            user_id=run.user_id,
            event_type=event_type,
            dedupe_key=dedupe_key,
            payload=payload or {},
        )
        .on_conflict_do_nothing(index_elements=[ProcessingEvent.run_id, ProcessingEvent.dedupe_key])
    )


async def enqueue_source_version(
    user: User,
    source: Source,
    *,
    filename: str | None,
    content: str | None,
    content_base64: str | None,
    source_url: str | None,
    db: AsyncSession,
    idempotency_key: str | None = None,
    causation_id: uuid.UUID | None = None,
) -> ProcessingRun:
    payload = {
        "filename": filename,
        "content": content,
        "content_base64": content_base64,
        "source_url": source_url,
    }
    content_fingerprint = _fingerprint(
        {"source_type": source.source_type.value, "payload": payload}
    )
    key = idempotency_key or f"source-version:{source.id}:{content_fingerprint}"
    request_hash = _fingerprint(
        {"source_id": str(source.id), "content_fingerprint": content_fingerprint}
    )
    await db.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"request:{user.id}:{key}", 0)))
    )
    await db.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"source:{source.id}", 0)))
    )
    await db.execute(
        select(Source.id).where(Source.id == source.id, Source.user_id == user.id).with_for_update()
    )
    version = await db.scalar(
        select(SourceVersion).where(
            SourceVersion.source_id == source.id,
            SourceVersion.fingerprint == content_fingerprint,
        )
    )
    duplicate_version = version is not None
    if version is None:
        version_number = (
            await db.scalar(
                select(func.max(SourceVersion.version_number)).where(
                    SourceVersion.source_id == source.id
                )
            )
            or 0
        ) + 1
        version = SourceVersion(
            source_id=source.id,
            version_number=version_number,
            fingerprint=content_fingerprint,
            filename=filename,
            payload=payload,
            status="pending",
        )
        db.add(version)
        await db.flush()
    request = await db.scalar(
        select(ProcessingEnqueueRequest).where(
            ProcessingEnqueueRequest.user_id == user.id,
            ProcessingEnqueueRequest.idempotency_key == key,
        )
    )
    if request is not None:
        if request.request_hash != request_hash:
            raise WikiBaseError(
                409,
                "idempotency_conflict",
                "Idempotency-Key was already used for different source content",
            )
        run = await db.get(ProcessingRun, request.run_id)
        if run is None:
            raise RuntimeError("Idempotent processing run is no longer available")
        if source.current_version_id is not None:
            source.status = SourceStatus.READY
        elif run.status in {"failed", "cancelled"}:
            source.status = SourceStatus.FAILED
            source.import_error = run.error
        await db.commit()
        stored = await get_run(user, run.id, db)
        stored.is_duplicate = True
        return stored

    run = await db.scalar(
        select(ProcessingRun)
        .where(
            ProcessingRun.user_id == user.id,
            ProcessingRun.source_version_id == version.id,
        )
        .order_by(ProcessingRun.created_at)
    )
    if run is not None:
        db.add(
            ProcessingEnqueueRequest(
                user_id=user.id,
                run_id=run.id,
                source_version_id=version.id,
                idempotency_key=key,
                request_hash=request_hash,
            )
        )
        if source.current_version_id is not None:
            source.status = SourceStatus.READY
        elif run.status in {"failed", "cancelled"}:
            source.status = SourceStatus.FAILED
            source.import_error = run.error
        await db.commit()
        stored = await get_run(user, run.id, db)
        stored.is_duplicate = True
        return stored

    policy = await get_processing_policy(user.id, db)
    snapshot = _policy_snapshot(policy)
    run = ProcessingRun(
        user_id=user.id,
        source_id=source.id,
        source_version_id=version.id,
        idempotency_key=key,
        causation_id=causation_id,
        status="queued" if policy.process_sources else "paused",
        current_stage="parse_index",
        policy_snapshot=snapshot,
        pause_reason=None if policy.process_sources else "source_processing_disabled",
    )
    db.add(run)
    await db.flush()
    db.add(
        ProcessingEnqueueRequest(
            user_id=user.id,
            run_id=run.id,
            source_version_id=version.id,
            idempotency_key=key,
            request_hash=request_hash,
        )
    )
    stages = []
    for position, name in enumerate(STAGE_NAMES):
        if name == "parse_index":
            stage_status = "queued" if policy.process_sources else "paused"
        else:
            stage_status = "blocked"
        stage = ProcessingStage(
            run_id=run.id,
            name=name,
            position=position,
            status=stage_status,
            max_attempts=MAX_ATTEMPTS[name],
            input_fingerprint=_fingerprint({"version": version.fingerprint, "stage": name}),
        )
        db.add(stage)
        stages.append(stage)
    await db.flush()
    await _event(db, run, "run_queued", "run:queued", payload={"source_version": str(version.id)})
    if source.current_version_id is None:
        source.status = SourceStatus.PENDING
    source.import_error = None
    await db.commit()
    stored = await get_run(user, run.id, db)
    stored.is_duplicate = duplicate_version
    return stored


async def trigger_source_rebuild(
    user: User,
    source_id: uuid.UUID,
    db: AsyncSession,
    *,
    idempotency_key: str,
) -> ProcessingRun:
    if not 16 <= len(idempotency_key) <= 128 or not all(
        char.isalnum() or char in "-_" for char in idempotency_key
    ):
        raise WikiBaseError(400, "invalid_idempotency_key", "Invalid Idempotency-Key header")
    source = await db.scalar(
        select(Source).where(Source.id == source_id, Source.user_id == user.id)
    )
    if source is None or source.current_version_id is None:
        raise NotFoundError("A current source version is required for rebuilding")
    version = await db.get(SourceVersion, source.current_version_id)
    if version is None:
        raise NotFoundError("Current source version not found")
    return await enqueue_source_version(
        user,
        source,
        filename=version.filename,
        content=version.payload.get("content"),
        content_base64=version.payload.get("content_base64"),
        source_url=version.payload.get("source_url"),
        db=db,
        idempotency_key=idempotency_key,
    )


async def get_run(user: User, run_id: uuid.UUID, db: AsyncSession) -> ProcessingRun:
    run = await db.scalar(
        select(ProcessingRun)
        .options(selectinload(ProcessingRun.stages), selectinload(ProcessingRun.events))
        .where(ProcessingRun.id == run_id, ProcessingRun.user_id == user.id)
    )
    if run is None:
        raise NotFoundError("Processing run not found")
    return run


async def list_runs(
    user: User,
    db: AsyncSession,
    *,
    source_id: uuid.UUID | None = None,
    limit: int = 100,
    latest_per_source: bool = False,
) -> list[ProcessingRun]:
    statement = (
        select(ProcessingRun)
        .options(selectinload(ProcessingRun.stages), selectinload(ProcessingRun.events))
        .where(ProcessingRun.user_id == user.id)
    )
    if latest_per_source:
        ranked = select(
            ProcessingRun.id.label("run_id"),
            func.row_number()
            .over(
                partition_by=ProcessingRun.source_id,
                order_by=(ProcessingRun.created_at.desc(), ProcessingRun.id.desc()),
            )
            .label("position"),
        ).where(ProcessingRun.user_id == user.id)
        if source_id is not None:
            ranked = ranked.where(ProcessingRun.source_id == source_id)
        ranked = ranked.subquery()
        statement = statement.where(
            ProcessingRun.id.in_(select(ranked.c.run_id).where(ranked.c.position == 1))
        )
    elif source_id is not None:
        statement = statement.where(ProcessingRun.source_id == source_id)
    statement = statement.order_by(ProcessingRun.created_at.desc(), ProcessingRun.id.desc()).limit(
        limit
    )
    return list((await db.execute(statement)).scalars().unique())


async def cancel_run(user: User, run_id: uuid.UUID, db: AsyncSession) -> ProcessingRun:
    run = await db.scalar(
        select(ProcessingRun)
        .where(ProcessingRun.id == run_id, ProcessingRun.user_id == user.id)
        .with_for_update()
    )
    if run is None:
        raise NotFoundError("Processing run not found")
    if run.status in {"ready", "failed", "cancelled"}:
        raise WikiBaseError(409, "run_terminal", "The processing run is already complete")
    now = _now()
    run.status = "cancelled"
    run.cancelled_at = now
    run.completed_at = now
    await db.execute(
        update(ProcessingStage)
        .where(
            ProcessingStage.run_id == run.id,
            ProcessingStage.status.in_(["blocked", "queued", "running", "paused"]),
        )
        .values(status="cancelled", completed_at=now, lease_owner=None, lease_expires_at=None)
    )
    version = await db.get(SourceVersion, run.source_version_id)
    source = await db.get(Source, run.source_id)
    if (
        version is not None
        and version.status != "ready"
        and source is not None
        and source.current_version_id != version.id
    ):
        version.status = "cancelled"
    if source is not None:
        if source.current_version_id is not None:
            source.status = SourceStatus.READY
        else:
            source.status = SourceStatus.FAILED
            source.import_error = "Processing was cancelled"
    await _event(db, run, "run_cancelled", "run:cancelled")
    await db.commit()
    return await get_run(user, run.id, db)


async def retry_run(
    user: User, run_id: uuid.UUID, db: AsyncSession, *, from_stage: str | None = None
) -> ProcessingRun:
    run = await db.scalar(
        select(ProcessingRun)
        .options(selectinload(ProcessingRun.stages))
        .where(ProcessingRun.id == run_id, ProcessingRun.user_id == user.id)
        .with_for_update()
    )
    if run is None:
        raise NotFoundError("Processing run not found")
    if run.status not in {"failed", "paused", "cancelled"}:
        raise WikiBaseError(
            409,
            "run_not_retryable",
            "Only failed, paused, or cancelled runs can be retried",
        )
    policy = await get_processing_policy(user.id, db)
    if not policy.process_sources:
        raise WikiBaseError(
            409,
            "source_processing_disabled",
            "Enable source processing before retrying this run",
        )
    failed = next(
        (stage for stage in run.stages if stage.status in {"failed", "paused", "cancelled"}),
        None,
    )
    target_name = from_stage or (failed.name if failed else None)
    if target_name not in STAGE_NAMES or failed is None:
        raise WikiBaseError(409, "nothing_to_retry", "The run has no failed or paused stage")
    target_position = STAGE_NAMES.index(target_name)
    if target_position != failed.position:
        raise WikiBaseError(409, "invalid_retry_stage", "Retry must start at the failed stage")
    for stage in run.stages:
        if stage.position < target_position:
            continue
        stage.status = "queued" if stage.position == target_position else "blocked"
        stage.attempt_count = 0
        stage.available_at = _now()
        stage.lease_owner = None
        stage.lease_expires_at = None
        stage.error = None
        stage.error_code = None
        if stage.position > target_position:
            stage.outcome = {}
            stage.output_fingerprint = None
    run.status = "queued"
    run.current_stage = target_name
    run.pause_reason = None
    run.error = None
    run.error_code = None
    run.completed_at = None
    run.cancelled_at = None
    await _event(
        db,
        run,
        "run_retried",
        f"retry:{run.attempt_count + 1}:{target_name}",
        payload={"from_stage": target_name},
    )
    run.attempt_count += 1
    await db.commit()
    return await get_run(user, run.id, db)


async def _fail_expired_exhausted_stage(db: AsyncSession, now: datetime) -> bool:
    stage = await db.scalar(
        select(ProcessingStage)
        .where(
            ProcessingStage.status == "running",
            ProcessingStage.lease_expires_at < now,
            ProcessingStage.attempt_count >= ProcessingStage.max_attempts,
        )
        .order_by(ProcessingStage.lease_expires_at, ProcessingStage.id)
        .with_for_update(skip_locked=True)
        .limit(1)
    )
    if stage is None:
        return False

    run = await db.scalar(
        select(ProcessingRun).where(ProcessingRun.id == stage.run_id).with_for_update()
    )
    error = "Stage lease expired after the maximum number of attempts"
    stage.status = "failed"
    stage.completed_at = now
    stage.error_code = "stage_failed"
    stage.error = error
    stage.lease_owner = None
    stage.lease_expires_at = None
    if run is not None and run.status not in {"ready", "failed", "cancelled"}:
        run.status = "failed"
        run.completed_at = now
        run.error_code = "stage_failed"
        run.error = error
        source = await db.get(Source, run.source_id)
        version = await db.get(SourceVersion, run.source_version_id)
        if version is not None and stage.name == "parse_index":
            version.status = "failed"
            version.error = error
        if source is not None and source.current_version_id is None:
            source.status = SourceStatus.FAILED
            source.import_error = error
        await _event(
            db,
            run,
            "stage_failed",
            f"stage:{stage.name}:failed",
            stage=stage,
            payload={"error_code": "stage_failed"},
        )
        await upsert_notification(
            db,
            user_id=run.user_id,
            kind="processing_attention",
            title="A source needs attention",
            body=(
                f"{stage.name.replace('_', ' ').title()} failed. "
                "Your last valid output is unchanged."
            ),
            href=f"/sources?run={run.id}",
            dedupe_key=f"processing-failed:{run.id}:{stage.name}",
        )
    await db.commit()
    return True


async def claim_stage(db: AsyncSession, worker_id: str) -> ProcessingStage | None:
    now = await db.scalar(select(func.clock_timestamp()))
    while await _fail_expired_exhausted_stage(db, now):
        now = await db.scalar(select(func.clock_timestamp()))
    stage = await db.scalar(
        select(ProcessingStage)
        .join(ProcessingRun, ProcessingRun.id == ProcessingStage.run_id)
        .join(ProcessingPolicy, ProcessingPolicy.user_id == ProcessingRun.user_id)
        .where(
            ProcessingPolicy.process_sources.is_(True),
            ProcessingRun.status.in_(["queued", "running"]),
            ProcessingStage.attempt_count < ProcessingStage.max_attempts,
            (
                ((ProcessingStage.status == "queued") & (ProcessingStage.available_at <= now))
                | ((ProcessingStage.status == "running") & (ProcessingStage.lease_expires_at < now))
            ),
        )
        .order_by(ProcessingStage.available_at, ProcessingRun.created_at, ProcessingStage.position)
        .with_for_update(skip_locked=True)
        .limit(1)
    )
    if stage is None:
        return None
    run = await db.get(ProcessingRun, stage.run_id)
    stage.status = "running"
    stage.attempt_count += 1
    stage.lease_owner = worker_id
    stage.lease_token += 1
    stage.lease_expires_at = now + timedelta(seconds=LEASE_SECONDS)
    stage.started_at = stage.started_at or now
    if run is not None:
        run.status = "running"
        run.current_stage = stage.name
        run.started_at = run.started_at or now
        await _event(
            db,
            run,
            "stage_started",
            f"stage:{stage.name}:attempt:{stage.attempt_count}:started",
            stage=stage,
            payload={"attempt": stage.attempt_count},
        )
    await db.commit()
    return stage


async def heartbeat_stage(
    db: AsyncSession,
    stage_id: uuid.UUID,
    worker_id: str,
    lease_token: int,
) -> bool:
    now = await db.scalar(select(func.clock_timestamp()))
    result = await db.execute(
        update(ProcessingStage)
        .where(
            ProcessingStage.id == stage_id,
            ProcessingStage.status == "running",
            ProcessingStage.lease_owner == worker_id,
            ProcessingStage.lease_token == lease_token,
            ProcessingStage.lease_expires_at > now,
        )
        .values(lease_expires_at=now + timedelta(seconds=LEASE_SECONDS))
    )
    await db.commit()
    return result.rowcount == 1


async def _heartbeat_while_running(
    stage_id: uuid.UUID,
    worker_id: str,
    lease_token: int,
) -> None:
    while True:
        await asyncio.sleep(max(1, LEASE_SECONDS // 3))
        async with async_session_factory() as heartbeat_db:
            if not await heartbeat_stage(heartbeat_db, stage_id, worker_id, lease_token):
                return


async def _activate_version(source: Source, version: SourceVersion, db: AsyncSession) -> bool:
    current = (
        await db.get(SourceVersion, source.current_version_id)
        if source.current_version_id is not None
        else None
    )
    if current is not None and current.version_number > version.version_number:
        return False
    source.current_version_id = version.id
    source.status = SourceStatus.READY
    source.import_error = None
    source.last_imported_at = _now()
    return True


async def _parse_index(
    run: ProcessingRun, version: SourceVersion, source: Source, db: AsyncSession
) -> dict:
    await db.execute(delete(SourceChunk).where(SourceChunk.source_version_id == version.id))
    parsed = await asyncio.to_thread(
        parse_source_payload,
        source,
        SourceParseItem(source_id=source.id, **version.payload),
    )
    if parsed.metadata_only:
        activated = await _activate_version(source, version, db)
        version.status = "ready"
        version.ready_at = _now()
        return {
            "chunk_count": 0,
            "metadata_only": True,
            **({} if activated else {"skipped": "superseded"}),
        }

    sections = parsed.sections or [SourceImportSection(content=parsed.content)]
    chunks: list[SourceChunk] = []
    meta = ChunkMeta(
        module_id=str(source.id),
        source_type=SourceType.PAGE,
        source_id=str(source.id),
        source_title=source.title,
        source_url=source.source_url,
    )
    for section in sections:
        for section_index, item in enumerate(chunk_text(section.content, meta)):
            index = len(chunks)
            citation = section.citation_ref or source.citation_label
            if section.location_label:
                citation = f"{citation}: {section.location_label}"
            if section_index:
                citation = f"{citation}#{section_index + 1}"
            chunk = SourceChunk(
                source_id=source.id,
                source_version_id=version.id,
                fingerprint=_fingerprint(
                    {
                        "content": item.content,
                        "citation": citation,
                        "location": section.location_label,
                    }
                ),
                chunk_index=index,
                citation_ref=citation,
                location_label=section.location_label,
                content=item.content,
                token_count=item.token_count,
            )
            db.add(chunk)
            chunks.append(chunk)
    if not chunks:
        raise ValueError("No importable text found")
    await db.flush()
    if get_settings().openai_api_key.strip():
        await embed_chunks(chunks, db)
    activated = await _activate_version(source, version, db)
    version.status = "ready"
    version.ready_at = _now()
    return {
        "chunk_count": len(chunks),
        "fingerprint": version.fingerprint,
        **({} if activated else {"skipped": "superseded"}),
    }


async def _execute_stage(run: ProcessingRun, stage: ProcessingStage, db: AsyncSession) -> dict:
    await db.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"source:{run.source_id}", 0)))
    )
    source = await db.scalar(
        select(Source)
        .where(Source.id == run.source_id, Source.user_id == run.user_id)
        .with_for_update()
    )
    version = await db.get(SourceVersion, run.source_version_id)
    user = await db.get(User, run.user_id)
    if source is None or version is None or user is None:
        raise RuntimeError("Processing input is no longer available")
    if stage.name == "parse_index":
        version.status = "processing"
        current = (
            await db.get(SourceVersion, source.current_version_id)
            if source.current_version_id is not None
            else None
        )
        if current is None or current.version_number <= version.version_number:
            source.status = SourceStatus.INDEXING
        return await _parse_index(run, version, source, db)
    if source.current_version_id != version.id:
        return {"skipped": "superseded"}
    if stage.name == "topic_proposals":
        if not run.policy_snapshot.get("map_topics", True):
            return {"skipped": "automation_disabled"}
        if source.enrollment_id is None:
            return {"skipped": "source_not_scoped_to_enrollment"}
        enrollment = await db.scalar(
            select(ModuleEnrollment).where(
                ModuleEnrollment.id == source.enrollment_id,
                ModuleEnrollment.user_id == run.user_id,
            )
        )
        if enrollment is None:
            return {"skipped": "enrollment_unavailable"}
        result = await generate_proposals(enrollment, [source.id], user, db)
        return {
            "enrollment_id": str(enrollment.id),
            **{key: value for key, value in result.items() if key != "associations"},
        }
    if stage.name == "coverage":
        if source.enrollment_id is None:
            return {"skipped": "source_not_scoped_to_enrollment"}
        enrollment = await db.scalar(
            select(ModuleEnrollment).where(
                ModuleEnrollment.id == source.enrollment_id,
                ModuleEnrollment.user_id == run.user_id,
            )
        )
        if enrollment is None:
            return {"skipped": "enrollment_unavailable"}
        dashboard = await coverage_dashboard(enrollment, db)
        dashboard_snapshot = _json_compatible(dashboard)
        dashboard_fingerprint = _fingerprint(dashboard_snapshot)
        await db.execute(
            insert(ProcessingCoverageSnapshot)
            .values(
                run_id=run.id,
                enrollment_id=enrollment.id,
                source_version_id=version.id,
                fingerprint=dashboard_fingerprint,
                snapshot=dashboard_snapshot,
            )
            .on_conflict_do_update(
                index_elements=[
                    ProcessingCoverageSnapshot.enrollment_id,
                    ProcessingCoverageSnapshot.source_version_id,
                ],
                set_={
                    "run_id": run.id,
                    "fingerprint": dashboard_fingerprint,
                    "snapshot": dashboard_snapshot,
                    "created_at": _now(),
                },
            )
        )
        return {
            "enrollment_id": str(enrollment.id),
            "numerator": dashboard["numerator"],
            "denominator": dashboard["denominator"],
            "provisional": dashboard["provisional"],
            "fingerprint": dashboard_fingerprint,
        }
    if stage.name == "wiki":
        if not run.policy_snapshot.get("compile_wiki", True):
            return {"skipped": "automation_disabled"}
        if source.current_version_id != version.id:
            return {"skipped": "superseded"}
        pages = await compile_workspace_wiki(user, db, [source.id], commit=False)
        return {
            "enrollment_id": str(source.enrollment_id) if source.enrollment_id else None,
            "page_ids": [str(page.id) for page in pages],
            "page_slugs": [page.slug for page in pages],
            "page_count": len(pages),
        }
    if stage.name == "flashcards":
        mode = run.policy_snapshot.get("flashcard_mode", "suggest")
        if mode == "off":
            return {"skipped": "automation_disabled"}
        if mode == "suggest":
            return {"suggested": True, "action": "/flashcards"}
        chunk_ids = list(
            (
                await db.execute(
                    select(SourceChunk.id)
                    .where(SourceChunk.source_version_id == version.id)
                    .order_by(SourceChunk.chunk_index)
                )
            ).scalars()
        )
        if not chunk_ids:
            return {"skipped": "insufficient_cited_context"}
        try:
            outcome = await generate_flashcard_deck(
                user,
                FlashcardGenerateRequest(source_chunk_ids=chunk_ids, limit=10),
                db,
                generation_policy={
                    "origin": "processing_pipeline",
                    "review": True,
                    "processing_policy": run.policy_snapshot,
                },
                commit=False,
            )
        except WikiBaseError as exc:
            if exc.error in {
                "provider_not_configured",
                "credential_unavailable",
                "reauth_required",
                "provider_authentication_failed",
                "provider_unavailable",
                "local_codex_unavailable",
                "local_codex_login_required",
            }:
                raise ProviderUnavailableError(exc.detail) from exc
            raise
        if outcome.deck is None:
            return {"skipped": "insufficient_cited_context", "message": outcome.message}
        return {
            "deck_id": str(outcome.deck.id),
            "enrollment_id": str(source.enrollment_id) if source.enrollment_id else None,
            "lifecycle": "draft",
        }
    raise RuntimeError("Unknown processing stage")


async def execute_claimed_stage(
    db: AsyncSession,
    stage_id: uuid.UUID,
    worker_id: str,
    lease_token: int | None = None,
) -> ProcessingRun | None:
    stage = await db.get(ProcessingStage, stage_id)
    now = await db.scalar(select(func.clock_timestamp()))
    if (
        stage is None
        or stage.status != "running"
        or stage.lease_owner != worker_id
        or stage.lease_expires_at is None
        or stage.lease_expires_at <= now
        or (lease_token is not None and stage.lease_token != lease_token)
    ):
        return None
    token = stage.lease_token
    run = await db.scalar(
        select(ProcessingRun)
        .options(selectinload(ProcessingRun.stages))
        .where(ProcessingRun.id == stage.run_id)
    )
    if run is None or run.status == "cancelled":
        return run

    run_id = run.id
    stage_name = stage.name
    stage_position = stage.position
    attempt_count = stage.attempt_count
    max_attempts = stage.max_attempts
    heartbeat = asyncio.create_task(_heartbeat_while_running(stage.id, worker_id, token))
    try:
        outcome = await _execute_stage(run, stage, db)
    except asyncio.CancelledError:
        try:
            await db.rollback()
        finally:
            heartbeat.cancel()
            try:
                await heartbeat
            except asyncio.CancelledError:
                pass
        raise
    except Exception as exc:
        await db.rollback()
        heartbeat.cancel()
        try:
            await heartbeat
        except asyncio.CancelledError:
            pass

        failed_at = await db.scalar(select(func.clock_timestamp()))
        provider_pause = isinstance(exc, ProviderUnavailableError)
        error = _safe_error(exc)
        if provider_pause:
            stage_values = {
                "status": "paused",
                "error_code": "provider_unavailable",
                "error": error,
                "lease_owner": None,
                "lease_expires_at": None,
            }
        elif attempt_count < max_attempts:
            delay = RETRY_DELAYS[min(attempt_count - 1, len(RETRY_DELAYS) - 1)]
            available_at = failed_at + timedelta(seconds=delay)
            stage_values = {
                "status": "queued",
                "available_at": available_at,
                "error_code": "stage_failed",
                "error": error,
                "lease_owner": None,
                "lease_expires_at": None,
            }
        else:
            stage_values = {
                "status": "failed",
                "completed_at": failed_at,
                "error_code": "stage_failed",
                "error": error,
                "lease_owner": None,
                "lease_expires_at": None,
            }
        fenced = await db.execute(
            update(ProcessingStage)
            .where(
                ProcessingStage.id == stage_id,
                ProcessingStage.status == "running",
                ProcessingStage.lease_owner == worker_id,
                ProcessingStage.lease_token == token,
                ProcessingStage.lease_expires_at > failed_at,
            )
            .values(**stage_values)
        )
        if fenced.rowcount != 1:
            await db.rollback()
            return None
        run = await db.get(ProcessingRun, run_id)
        if run is None or run.status == "cancelled":
            await db.rollback()
            return run
        if provider_pause:
            run.status = "paused"
            run.pause_reason = "provider_unavailable"
            run.error_code = "provider_unavailable"
            run.error = error
            await _event(
                db,
                run,
                "stage_paused",
                f"stage:{stage_name}:provider-paused",
                stage=stage,
                payload={"action": "/settings/providers"},
            )
            await upsert_notification(
                db,
                user_id=run.user_id,
                kind="processing_attention",
                title="Source processing is paused",
                body="Connect and activate a generation provider to prepare flashcards.",
                href="/settings/providers",
                dedupe_key=f"processing-paused:{run.id}",
            )
        elif attempt_count < max_attempts:
            run.status = "queued"
            run.next_attempt_at = available_at
            await _event(
                db,
                run,
                "stage_retry_scheduled",
                f"stage:{stage_name}:attempt:{attempt_count}:retry",
                stage=stage,
                payload={"attempt": attempt_count, "retry_in_seconds": delay},
            )
        else:
            completed_at = _now()
            run.status = "failed"
            run.completed_at = completed_at
            run.error_code = "stage_failed"
            run.error = error
            source = await db.get(Source, run.source_id)
            version = await db.get(SourceVersion, run.source_version_id)
            if version is not None and stage_name == "parse_index":
                version.status = "failed"
                version.error = error
            if source is not None and source.current_version_id is None:
                source.status = SourceStatus.FAILED
                source.import_error = error
            await _event(
                db,
                run,
                "stage_failed",
                f"stage:{stage_name}:failed",
                stage=stage,
                payload={"error_code": "stage_failed"},
            )
            await upsert_notification(
                db,
                user_id=run.user_id,
                kind="processing_attention",
                title="A source needs attention",
                body=(
                    f"{stage_name.replace('_', ' ').title()} failed. "
                    "Your last valid output is unchanged."
                ),
                href=f"/sources?run={run.id}",
                dedupe_key=f"processing-failed:{run.id}:{stage_name}",
            )
        await db.commit()
        return run

    heartbeat.cancel()
    try:
        await heartbeat
    except asyncio.CancelledError:
        pass

    completed_at = await db.scalar(select(func.clock_timestamp()))
    completed_status = "skipped" if "skipped" in outcome else "succeeded"
    fenced = await db.execute(
        update(ProcessingStage)
        .where(
            ProcessingStage.id == stage_id,
            ProcessingStage.status == "running",
            ProcessingStage.lease_owner == worker_id,
            ProcessingStage.lease_token == token,
            ProcessingStage.lease_expires_at > completed_at,
        )
        .values(
            status=completed_status,
            outcome=outcome,
            output_fingerprint=_fingerprint(outcome),
            completed_at=completed_at,
            lease_owner=None,
            lease_expires_at=None,
        )
    )
    if fenced.rowcount != 1:
        await db.rollback()
        return None
    await _event(
        db,
        run,
        "stage_completed",
        f"stage:{stage_name}:completed",
        stage=stage,
        payload={"status": completed_status},
    )
    next_stage = next((item for item in run.stages if item.position == stage_position + 1), None)
    if next_stage is None:
        run.status = "ready"
        run.current_stage = "ready"
        run.completed_at = completed_at
        run.error = None
        run.error_code = None
        await _event(db, run, "run_ready", "run:ready")
        await upsert_notification(
            db,
            user_id=run.user_id,
            kind="processing_complete",
            title="Source processing is ready",
            body="Your source evidence and enabled study outputs are ready.",
            href=f"/sources?run={run.id}",
            dedupe_key=f"processing-ready:{run.id}",
        )
        await db.execute(
            delete(InAppNotification).where(
                InAppNotification.user_id == run.user_id,
                InAppNotification.dedupe_key.like(f"processing-failed:{run.id}:%"),
            )
        )
    else:
        policy_enabled = await db.scalar(
            select(ProcessingPolicy.process_sources).where(ProcessingPolicy.user_id == run.user_id)
        )
        if policy_enabled:
            next_stage.status = "queued"
            next_stage.available_at = completed_at
            run.status = "queued"
            run.pause_reason = None
        else:
            next_stage.status = "paused"
            run.status = "paused"
            run.pause_reason = "source_processing_disabled"
        run.current_stage = next_stage.name
        run.next_attempt_at = completed_at
    await db.commit()
    return run


async def work_once(db: AsyncSession, worker_id: str) -> ProcessingRun | None:
    stage = await claim_stage(db, worker_id)
    if stage is None:
        return None
    return await execute_claimed_stage(db, stage.id, worker_id, stage.lease_token)
