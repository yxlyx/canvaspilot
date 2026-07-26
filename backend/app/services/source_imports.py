import hashlib
import json
import uuid
from datetime import UTC, datetime

from pydantic import ValidationError
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import IngestionJobStateError, NotFoundError
from app.models.content import SourceType
from app.models.ingestion_job import IngestionJob
from app.models.m3 import SourceChange
from app.models.processing import SourceVersion
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.schemas.source_imports import (
    MAX_IMPORT_TEXT_CHARS,
    MAX_SOURCE_CHUNKS,
    SourceImportItem,
    SourceImportSection,
    SourceParseItem,
)
from app.services.embedding import embed_chunks
from app.services.ingestion import ChunkMeta, chunk_text
from app.services.ingestion_jobs import (
    get_owned_ingestion_job,
    mark_ingestion_job_completed,
    mark_ingestion_job_failed,
    mark_ingestion_job_running,
)
from app.services.notifications import sync_attention_notifications
from app.services.source_parsers import SourceParseError, parse_source_payload


def _content_snapshot(source: Source, chunks: list[SourceChunk]) -> dict:
    digest = hashlib.sha256()
    for chunk in sorted(chunks, key=lambda item: item.chunk_index):
        digest.update(chunk.content.encode())
        digest.update(b"\0")
    return {
        "title": source.title,
        "status": source.status.value,
        "chunk_count": len(chunks),
        "content_sha256": digest.hexdigest(),
    }


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
    payload = item.model_dump(mode="json")
    fingerprint = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    version = await db.scalar(
        select(SourceVersion).where(
            SourceVersion.source_id == source.id,
            SourceVersion.fingerprint == fingerprint,
        )
    )
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
            fingerprint=fingerprint,
            payload=payload,
            status="processing",
        )
        db.add(version)
        await db.flush()
    else:
        version.status = "processing"
        version.error = None
    await db.execute(delete(SourceChunk).where(SourceChunk.source_version_id == version.id))
    if item.metadata_only:
        raise ValueError("Metadata-only sources cannot be published as ready content")

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
        if len(chunks) + len(text_chunks) > MAX_SOURCE_CHUNKS:
            raise ValueError("Source exceeds the maximum supported chunk count")
        for section_chunk_index, text_chunk in enumerate(text_chunks):
            chunk_index = len(chunks)
            citation_ref = _citation_ref(source, section, chunk_index, section_chunk_index)
            chunk = SourceChunk(
                source_id=source.id,
                source_version_id=version.id,
                fingerprint=hashlib.sha256(
                    json.dumps(
                        {
                            "content": text_chunk.content,
                            "citation": citation_ref,
                            "location": section.location_label,
                        },
                        sort_keys=True,
                        separators=(",", ":"),
                    ).encode()
                ).hexdigest(),
                chunk_index=chunk_index,
                citation_ref=citation_ref,
                location_label=section.location_label,
                content=text_chunk.content,
                token_count=text_chunk.token_count,
            )
            db.add(chunk)
            chunks.append(chunk)

    if not chunks:
        raise ValueError("No importable text found")

    await db.flush()
    current = (
        await db.get(SourceVersion, source.current_version_id)
        if source.current_version_id is not None
        else None
    )
    if current is None or current.version_number <= version.version_number:
        source.current_version_id = version.id
    version.status = "ready"
    version.ready_at = datetime.now(UTC)
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
    source_refs = [(source.id, source.title) for source in sources]
    payload_by_source_id = {item.source_id: item for item in payload_sources}
    imported_source_count = 0
    chunk_count = 0
    errors: list[str] = []

    for source_id, source_title in source_refs:
        await db.execute(
            select(func.pg_advisory_xact_lock(func.hashtextextended(f"source:{source_id}", 0)))
        )
        source = (
            await db.execute(select(Source).where(Source.id == source_id).with_for_update())
        ).scalar_one_or_none()
        if source is None or source.user_id != user_id:
            raise NotFoundError("Source not found")
        before_snapshot = _content_snapshot(source, list(source.chunks))
        try:
            source.status = SourceStatus.INDEXING
            source.import_error = None
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
        except Exception as exc:
            await db.rollback()
            failed_source = await db.get(Source, source_id)
            error_message = str(exc) or "Import failed"
            if failed_source is not None:
                failed_status = (
                    SourceStatus.READY
                    if failed_source.current_version_id is not None
                    else SourceStatus.FAILED
                )
                failed_source.status = failed_status
                failed_source.import_error = error_message
                db.add(
                    SourceChange(
                        user_id=user_id,
                        source_id=source_id,
                        source_title=source_title,
                        change_type="source_import_failed",
                        before_snapshot=before_snapshot,
                        after_snapshot={
                            **before_snapshot,
                            "status": failed_status.value,
                            "import_error": error_message,
                        },
                    )
                )
            errors.append(f"{source_title}: {error_message}")
            await sync_attention_notifications(user_id, db)
            await db.commit()
            continue

        source.status = SourceStatus.READY
        source.import_error = None
        source.last_imported_at = datetime.now(UTC)
        after_snapshot = _content_snapshot(source, chunks)
        if before_snapshot != after_snapshot:
            db.add(
                SourceChange(
                    user_id=user_id,
                    source_id=source.id,
                    source_title=source.title,
                    change_type="source_content_imported",
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                )
            )
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
    parsed_text_chars = 0
    for source in sources:
        try:
            item = parse_source_payload(source, payload_by_source_id[source.id])
            parsed_text_chars += len(item.content) + sum(
                len(section.content) for section in item.sections
            )
            if parsed_text_chars > MAX_IMPORT_TEXT_CHARS:
                raise SourceParseError("Aggregate parsed text exceeds 4,000,000 characters")
            import_items.append(item)
        except (SourceParseError, ValidationError) as exc:
            import_items.append(SourceImportItem(source_id=source.id, import_error=str(exc)))

    return await import_ingestion_job_sources(user, job_id, import_items, db)
