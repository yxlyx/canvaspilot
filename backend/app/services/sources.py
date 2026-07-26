import uuid
from datetime import UTC, datetime

from sqlalchemy import Select, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError, WikiBaseError
from app.models.curriculum import CurriculumTopic, ModuleEnrollment, TopicSourceAssociation
from app.models.m3 import SourceChange
from app.models.source import Source, SourceKind, SourceStatus
from app.models.user import User
from app.schemas.sources import SourceCreate, SourceUpdate, normalize_topic_tags

IMPORT_METADATA_FIELDS = (
    "enrollment_id",
    "citation_label",
    "topic_tags",
    "course_context",
    "project_context",
)


def source_snapshot(source: Source) -> dict:
    return {
        "enrollment_id": str(source.enrollment_id) if source.enrollment_id else None,
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


async def _validate_enrollment_scope(
    enrollment_id: uuid.UUID | None, user_id: uuid.UUID, db: AsyncSession
) -> None:
    if enrollment_id is None:
        return
    owned = await db.scalar(
        select(ModuleEnrollment.id).where(
            ModuleEnrollment.id == enrollment_id,
            ModuleEnrollment.user_id == user_id,
            ModuleEnrollment.archived.is_(False),
        )
    )
    if owned is None:
        raise NotFoundError("Active module enrollment not found")


async def create_or_update_source(
    user: User,
    payload: SourceCreate,
    db: AsyncSession,
) -> Source:
    await _validate_enrollment_scope(payload.enrollment_id, user.id, db)
    existing: Source | None = None
    if payload.external_id:
        import_key = f"{user.id}:{payload.origin}:{payload.external_id}"
        await db.execute(select(func.pg_advisory_xact_lock(func.hashtextextended(import_key, 0))))
        result = await db.execute(
            select(Source).where(
                Source.user_id == user.id,
                Source.origin == payload.origin,
                Source.external_id == payload.external_id,
            )
        )
        existing = result.scalar_one_or_none()

    if existing:
        user_overridden_fields = set(existing.metadata_overrides or [])
        desired_enrollment_id = (
            existing.enrollment_id
            if "enrollment_id" in user_overridden_fields
            else payload.enrollment_id
        )
        if desired_enrollment_id != existing.enrollment_id:
            existing = await _lock_source_reattachment(existing, desired_enrollment_id, db)
        else:
            existing = (
                await db.execute(
                    select(Source)
                    .where(Source.id == existing.id, Source.user_id == user.id)
                    .with_for_update()
                    .execution_options(populate_existing=True)
                )
            ).scalar_one()
        before = source_snapshot(existing)
        user_overridden_fields = set(existing.metadata_overrides or [])
        existing.source_type = payload.source_type
        existing.title = payload.title
        existing.source_url = payload.source_url
        incoming_metadata = {
            "enrollment_id": payload.enrollment_id,
            "citation_label": payload.citation_label or payload.title,
            "topic_tags": payload.topic_tags,
            "course_context": payload.course_context,
            "project_context": payload.project_context,
        }
        for field, value in incoming_metadata.items():
            if field not in user_overridden_fields:
                setattr(existing, field, value)
        existing.status = (
            SourceStatus.READY
            if existing.current_version_id is not None and payload.status == SourceStatus.PENDING
            else payload.status
        )
        existing.import_error = payload.import_error
        existing.last_imported_at = datetime.now(UTC)
        record_source_change(existing, before, db, "source_updated")
        await db.commit()
        await db.refresh(existing)
        return existing

    source = Source(
        user_id=user.id,
        enrollment_id=payload.enrollment_id,
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


async def _lock_source_reattachment(
    source: Source, enrollment_id: uuid.UUID | None, db: AsyncSession
) -> Source:
    await db.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"source:{source.id}", 0)))
    )
    current_enrollment_id = await db.scalar(
        select(Source.enrollment_id).where(Source.id == source.id, Source.user_id == source.user_id)
    )
    enrollment_ids = sorted(
        {value for value in (current_enrollment_id, enrollment_id) if value is not None}, key=str
    )
    enrollments = list(
        (
            await db.execute(
                select(ModuleEnrollment)
                .where(ModuleEnrollment.id.in_(enrollment_ids))
                .order_by(ModuleEnrollment.id)
                .with_for_update()
            )
        ).scalars()
    )
    if enrollment_id is not None and not any(
        row.id == enrollment_id and row.user_id == source.user_id and not row.archived
        for row in enrollments
    ):
        raise NotFoundError("Active module enrollment not found")
    await db.execute(
        select(CurriculumTopic.id)
        .where(CurriculumTopic.enrollment_id.in_(enrollment_ids))
        .order_by(CurriculumTopic.id)
        .with_for_update()
    )
    source = (
        await db.execute(
            select(Source)
            .where(Source.id == source.id, Source.user_id == source.user_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one()
    associations = list(
        (
            await db.execute(
                select(TopicSourceAssociation)
                .where(TopicSourceAssociation.source_id == source.id)
                .order_by(TopicSourceAssociation.id)
                .with_for_update()
            )
        ).scalars()
    )
    incompatible = [
        row
        for row in associations
        if enrollment_id is not None and row.enrollment_id != enrollment_id
    ]
    if any(row.status == "confirmed" for row in incompatible):
        raise WikiBaseError(
            409,
            "confirmed_association_scope_conflict",
            "Remove confirmed associations before moving this source",
        )
    now = datetime.now(UTC)
    for row in incompatible:
        row.status = "rejected"
        row.stale = True
        row.stale_reason = "source_scope_changed"
        row.reason_code = "source_scope_changed"
        row.reviewed_at = row.reviewed_at or now
        row.reviewer_id = row.reviewer_id or source.user_id
        row.updated_at = now
    return source


async def update_source(source: Source, payload: SourceUpdate, db: AsyncSession) -> Source:
    update_data = payload.model_dump(exclude_unset=True)
    if "enrollment_id" in update_data:
        await _validate_enrollment_scope(update_data["enrollment_id"], source.user_id, db)
        source = await _lock_source_reattachment(source, update_data["enrollment_id"], db)
    else:
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
