import uuid
from datetime import UTC, datetime

from sqlalchemy import Select, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.m3 import SourceChange
from app.models.source import Source, SourceKind, SourceStatus
from app.models.user import User
from app.schemas.sources import SourceCreate, SourceUpdate, normalize_topic_tags

IMPORT_METADATA_FIELDS = (
    "citation_label",
    "topic_tags",
    "course_context",
    "project_context",
)


def source_snapshot(source: Source) -> dict:
    return {
        "source_type": source.source_type.value,
        "title": source.title,
        "source_url": source.source_url,
        "citation_label": source.citation_label,
        "topic_tags": list(source.topic_tags or []),
        "status": source.status.value,
        "course_context": source.course_context,
        "project_context": source.project_context,
        "import_error": source.import_error,
    }


def record_source_change(source: Source, before: dict, db: AsyncSession, change_type: str) -> None:
    after = source_snapshot(source)
    if before != after:
        db.add(
            SourceChange(
                user_id=source.user_id,
                source_id=source.id,
                source_title=source.title,
                change_type=change_type,
                before_snapshot=before,
                after_snapshot=after,
            )
        )


def build_source_list_statement(
    user_id: uuid.UUID,
    source_type: SourceKind | None = None,
    status: SourceStatus | None = None,
    topic_tag: str | None = None,
    limit: int = 100,
) -> Select[tuple[Source]]:
    statement = select(Source).where(Source.user_id == user_id)

    if source_type is not None:
        statement = statement.where(Source.source_type == source_type)
    if status is not None:
        statement = statement.where(Source.status == status)
    if topic_tag:
        tag = normalize_topic_tags([topic_tag])
        if tag:
            statement = statement.where(Source.topic_tags.contains(tag))

    return statement.order_by(Source.updated_at.desc(), Source.title.asc()).limit(limit)


async def create_or_update_source(
    user: User,
    payload: SourceCreate,
    db: AsyncSession,
) -> Source:
    existing: Source | None = None
    if payload.external_id:
        import_key = f"{user.id}:{payload.origin}:{payload.external_id}"
        await db.execute(select(func.pg_advisory_xact_lock(func.hashtextextended(import_key, 0))))
        result = await db.execute(
            select(Source)
            .where(
                Source.user_id == user.id,
                Source.origin == payload.origin,
                Source.external_id == payload.external_id,
            )
            .with_for_update()
        )
        existing = result.scalar_one_or_none()

    if existing:
        before = source_snapshot(existing)
        user_overridden_fields = set(existing.metadata_overrides or [])
        existing.source_type = payload.source_type
        existing.title = payload.title
        existing.source_url = payload.source_url
        incoming_metadata = {
            "citation_label": payload.citation_label or payload.title,
            "topic_tags": payload.topic_tags,
            "course_context": payload.course_context,
            "project_context": payload.project_context,
        }
        for field, value in incoming_metadata.items():
            if field not in user_overridden_fields:
                setattr(existing, field, value)
        existing.status = payload.status
        existing.import_error = payload.import_error
        existing.last_imported_at = datetime.now(UTC)
        record_source_change(existing, before, db, "source_updated")
        await db.commit()
        await db.refresh(existing)
        return existing

    source = Source(
        user_id=user.id,
        source_type=payload.source_type,
        origin=payload.origin,
        external_id=payload.external_id,
        title=payload.title,
        source_url=payload.source_url,
        citation_label=payload.citation_label or payload.title,
        topic_tags=payload.topic_tags,
        status=payload.status,
        course_context=payload.course_context,
        project_context=payload.project_context,
        import_error=payload.import_error,
        last_imported_at=datetime.now(UTC),
    )
    db.add(source)
    await db.flush()
    db.add(
        SourceChange(
            user_id=user.id,
            source_id=source.id,
            source_title=source.title,
            change_type="source_created",
            before_snapshot={},
            after_snapshot=source_snapshot(source),
        )
    )
    await db.commit()
    await db.refresh(source)
    return source


async def update_source(source: Source, payload: SourceUpdate, db: AsyncSession) -> Source:
    update_data = payload.model_dump(exclude_unset=True)
    result = await db.execute(
        select(Source)
        .where(Source.id == source.id, Source.user_id == source.user_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    source = result.scalar_one()
    before = source_snapshot(source)

    for field, value in update_data.items():
        setattr(source, field, value)

    touched_metadata = set(update_data).intersection(IMPORT_METADATA_FIELDS)
    changed_metadata = {
        field for field in touched_metadata if before[field] != getattr(source, field)
    }
    if changed_metadata:
        source.metadata_overrides = sorted(
            set(source.metadata_overrides or []).union(changed_metadata)
        )
    change_type = "source_metadata_updated" if changed_metadata else "source_updated"
    record_source_change(source, before, db, change_type)
    await db.commit()
    await db.refresh(source)
    return source
