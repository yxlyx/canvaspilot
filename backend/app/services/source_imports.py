import uuid
from datetime import UTC, datetime

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import IngestionJobStateError, NotFoundError
from app.models.content import SourceType
from app.models.ingestion_job import IngestionJob
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.schemas.source_imports import SourceImportItem
from app.services.embedding import embed_chunks
from app.services.ingestion import ChunkMeta, chunk_text
from app.services.ingestion_jobs import (
    get_owned_ingestion_job,
    mark_ingestion_job_completed,
    mark_ingestion_job_failed,
    mark_ingestion_job_running,
)


def _citation_ref(source: Source, chunk_index: int) -> str:
    return f"{source.citation_label}#{chunk_index + 1}"


async def _load_job_sources(job: IngestionJob, user: User, db: AsyncSession) -> list[Source]:
    result = await db.execute(
        select(Source).where(Source.user_id == user.id, Source.id.in_(job.source_ids))
    )
    sources = result.scalars().all()
    if len(sources) != len(job.source_ids):
        raise NotFoundError("One or more sources were not found")
    return sorted(sources, key=lambda source: job.source_ids.index(source.id))


def _validate_payload_sources(job: IngestionJob, payload_sources: list[SourceImportItem]) -> None:
    expected_ids = set(job.source_ids)
    payload_ids = {item.source_id for item in payload_sources}
    if payload_ids != expected_ids:
        raise IngestionJobStateError("Import payload must match the ingestion job source batch")


async def _replace_source_chunks(
    source: Source,
    content: str,
    db: AsyncSession,
) -> list[SourceChunk]:
    await db.execute(delete(SourceChunk).where(SourceChunk.source_id == source.id))

    meta = ChunkMeta(
        module_id=str(source.id),
        source_type=SourceType.PAGE,
        source_id=str(source.id),
        source_title=source.title,
        source_url=source.source_url,
    )
    text_chunks = chunk_text(content, meta)
    if not text_chunks:
        raise ValueError("No importable text found")

    chunks: list[SourceChunk] = []
    for index, text_chunk in enumerate(text_chunks):
        chunk = SourceChunk(
            source_id=source.id,
            chunk_index=index,
            citation_ref=_citation_ref(source, index),
            content=text_chunk.content,
            token_count=text_chunk.token_count,
        )
        db.add(chunk)
        chunks.append(chunk)

    await db.flush()
    return chunks


async def import_ingestion_job_sources(
    user: User,
    job_id: uuid.UUID,
    payload_sources: list[SourceImportItem],
    db: AsyncSession,
) -> IngestionJob:
    user_id = user.id
    job = await get_owned_ingestion_job(user, job_id, db)
    _validate_payload_sources(job, payload_sources)
    job = await mark_ingestion_job_running(job, db)

    sources = await _load_job_sources(job, user, db)
    payload_by_source_id = {item.source_id: item for item in payload_sources}
    imported_source_count = 0
    chunk_count = 0
    errors: list[str] = []

    for source in sources:
        source_id = source.id
        source_title = source.title
        source.status = SourceStatus.INDEXING
        source.import_error = None
        await db.commit()
        await db.refresh(source)

        try:
            chunks = await _replace_source_chunks(
                source,
                payload_by_source_id[source_id].content,
                db,
            )
            await embed_chunks(chunks, db)
        except Exception as exc:
            await db.rollback()
            failed_source = await db.get(Source, source_id)
            error_message = str(exc) or "Import failed"
            if failed_source is not None:
                failed_source.status = SourceStatus.FAILED
                failed_source.import_error = error_message
            errors.append(f"{source_title}: {error_message}")
            await db.commit()
            continue

        source.status = SourceStatus.READY
        source.import_error = None
        source.last_imported_at = datetime.now(UTC)
        await db.commit()
        imported_source_count += 1
        chunk_count += len(chunks)

    if errors:
        result = await db.execute(
            select(IngestionJob).where(IngestionJob.id == job_id, IngestionJob.user_id == user_id)
        )
        failed_job = result.scalar_one_or_none()
        if failed_job is None:
            raise NotFoundError("Ingestion job not found")
        failed_job.imported_source_count = imported_source_count
        failed_job.chunk_count = chunk_count
        return await mark_ingestion_job_failed(failed_job, "; ".join(errors), db)

    return await mark_ingestion_job_completed(
        job,
        imported_source_count=imported_source_count,
        chunk_count=chunk_count,
        db=db,
    )
