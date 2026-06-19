import uuid
from datetime import UTC, datetime

from sqlalchemy import Select, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import IngestionJobConflictError, NotFoundError
from app.models.ingestion_job import ACTIVE_INGESTION_JOB_STATUSES, IngestionJob, IngestionJobStatus
from app.models.source import Source
from app.models.user import User


async def _find_active_job_for_batch(
    user_id: uuid.UUID, batch_key: str, db: AsyncSession
) -> IngestionJob | None:
    result = await db.execute(
        select(IngestionJob).where(
            IngestionJob.user_id == user_id,
            IngestionJob.batch_key == batch_key,
            IngestionJob.status.in_(ACTIVE_INGESTION_JOB_STATUSES),
        )
    )
    return result.scalar_one_or_none()


def build_batch_key(source_ids: list[uuid.UUID]) -> str:
    return "|".join(str(source_id) for source_id in sorted(source_ids))


def build_ingestion_job_list_statement(
    user_id: uuid.UUID,
    status: IngestionJobStatus | None = None,
) -> Select[tuple[IngestionJob]]:
    statement = select(IngestionJob).where(IngestionJob.user_id == user_id)
    if status is not None:
        statement = statement.where(IngestionJob.status == status)
    return statement.order_by(IngestionJob.created_at.desc())


async def _validate_owned_sources(
    user: User,
    source_ids: list[uuid.UUID],
    db: AsyncSession,
) -> list[uuid.UUID]:
    unique_source_ids = list(dict.fromkeys(source_ids))
    result = await db.execute(
        select(Source.id).where(Source.user_id == user.id, Source.id.in_(unique_source_ids))
    )
    owned_source_ids = {row[0] for row in result.all()}
    missing_source_ids = [
        source_id for source_id in unique_source_ids if source_id not in owned_source_ids
    ]
    if missing_source_ids:
        raise NotFoundError("One or more sources were not found")
    return unique_source_ids


async def create_queued_ingestion_job(
    user: User,
    source_ids: list[uuid.UUID],
    db: AsyncSession,
) -> IngestionJob:
    owned_source_ids = await _validate_owned_sources(user, source_ids, db)
    batch_key = build_batch_key(owned_source_ids)

    active_job = await _find_active_job_for_batch(user.id, batch_key, db)
    if active_job:
        raise IngestionJobConflictError(str(active_job.id))

    job = IngestionJob(
        user_id=user.id,
        status=IngestionJobStatus.QUEUED,
        source_ids=owned_source_ids,
        batch_key=batch_key,
        source_count=len(owned_source_ids),
    )
    db.add(job)
    try:
        await db.flush()
    except IntegrityError:
        await db.rollback()
        raise IngestionJobConflictError("concurrent") from None
    await db.commit()
    await db.refresh(job)
    return job


async def get_owned_ingestion_job(
    user: User,
    job_id: uuid.UUID,
    db: AsyncSession,
) -> IngestionJob:
    result = await db.execute(
        select(IngestionJob).where(IngestionJob.id == job_id, IngestionJob.user_id == user.id)
    )
    job = result.scalar_one_or_none()
    if not job:
        raise NotFoundError("Ingestion job not found")
    return job


async def mark_ingestion_job_running(job: IngestionJob, db: AsyncSession) -> IngestionJob:
    job.status = IngestionJobStatus.RUNNING
    job.started_at = datetime.now(UTC)
    await db.commit()
    await db.refresh(job)
    return job


async def mark_ingestion_job_completed(
    job: IngestionJob,
    imported_source_count: int,
    chunk_count: int,
    db: AsyncSession,
) -> IngestionJob:
    job.status = IngestionJobStatus.COMPLETED
    job.imported_source_count = imported_source_count
    job.chunk_count = chunk_count
    job.error_message = None
    job.completed_at = datetime.now(UTC)
    await db.commit()
    await db.refresh(job)
    return job


async def mark_ingestion_job_failed(
    job: IngestionJob,
    error_message: str,
    db: AsyncSession,
) -> IngestionJob:
    job.status = IngestionJobStatus.FAILED
    job.error_message = error_message.strip() or "Import failed"
    job.completed_at = datetime.now(UTC)
    await db.commit()
    await db.refresh(job)
    return job
