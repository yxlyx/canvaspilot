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
from app.schemas.source_imports import SourceImportItem, SourceImportSection, SourceParseItem
from app.services.embedding import embed_chunks
from app.services.ingestion import ChunkMeta, chunk_text
from app.services.ingestion_jobs import (
    get_owned_ingestion_job,
    mark_ingestion_job_completed,
    mark_ingestion_job_failed,
    mark_ingestion_job_running,
)
from app.services.source_parsers import SourceParseError, parse_source_payload


def _citation_ref(
    source: Source,
    section: SourceImportSection,
    chunk_index: int,
    section_chunk_index: int,
) -> str:
    if section.citation_ref:
        base_ref = section.citation_ref
    elif section.location_label:
        base_ref = f"{source.citation_label}: {section.location_label}"
    else:
        base_ref = source.citation_label

    if section_chunk_index > 0:
        return f"{base_ref}#{section_chunk_index + 1}"
    if not section.location_label and not section.citation_ref:
        return f"{base_ref}#{chunk_index + 1}"
    return base_ref


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


def _import_sections(item: SourceImportItem) -> list[SourceImportSection]:
    if item.sections:
        return item.sections
    return [
        SourceImportSection(
            content=item.content,
            citation_ref=item.citation_ref,
            location_label=item.location_label,
        )
    ]


async def _replace_source_chunks(
    source: Source,
    item: SourceImportItem,
    db: AsyncSession,
) -> list[SourceChunk]:
    await db.execute(delete(SourceChunk).where(SourceChunk.source_id == source.id))
    if item.metadata_only:
        await db.flush()
        return []

    meta = ChunkMeta(
        module_id=str(source.id),
        source_type=SourceType.PAGE,
        source_id=str(source.id),
        source_title=source.title,
        source_url=source.source_url,
    )
    chunks: list[SourceChunk] = []
    for section in _import_sections(item):
        text_chunks = chunk_text(section.content, meta)
        for section_chunk_index, text_chunk in enumerate(text_chunks):
            chunk_index = len(chunks)
            chunk = SourceChunk(
                source_id=source.id,
                chunk_index=chunk_index,
                citation_ref=_citation_ref(source, section, chunk_index, section_chunk_index),
                location_label=section.location_label,
                content=text_chunk.content,
                token_count=text_chunk.token_count,
            )
            db.add(chunk)
            chunks.append(chunk)

    if not chunks:
        raise ValueError("No importable text found")

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
            import_item = payload_by_source_id[source_id]
            if import_item.import_error:
                raise ValueError(import_item.import_error)
            chunks = await _replace_source_chunks(
                source,
                import_item,
                db,
            )
            if chunks:
                await embed_chunks(chunks, db)
            else:
                await db.commit()
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


async def parse_and_import_ingestion_job_sources(
    user: User,
    job_id: uuid.UUID,
    payload_sources: list[SourceParseItem],
    db: AsyncSession,
) -> IngestionJob:
    job = await get_owned_ingestion_job(user, job_id, db)
    sources = await _load_job_sources(job, user, db)
    _validate_payload_sources(
        job,
        [
            SourceImportItem(source_id=payload_source.source_id)
            for payload_source in payload_sources
        ],
    )

    payload_by_source_id = {item.source_id: item for item in payload_sources}
    import_items: list[SourceImportItem] = []
    for source in sources:
        try:
            import_items.append(parse_source_payload(source, payload_by_source_id[source.id]))
        except SourceParseError as exc:
            import_items.append(SourceImportItem(source_id=source.id, import_error=str(exc)))

    return await import_ingestion_job_sources(user, job_id, import_items, db)
