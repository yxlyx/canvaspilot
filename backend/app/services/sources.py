import uuid
from datetime import UTC, datetime

from sqlalchemy import Select, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.source import Source, SourceKind, SourceStatus
from app.models.user import User
from app.schemas.sources import SourceCreate, SourceUpdate, normalize_topic_tags


def build_source_list_statement(
    user_id: uuid.UUID,
    source_type: SourceKind | None = None,
    status: SourceStatus | None = None,
    topic_tag: str | None = None,
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

    return statement.order_by(Source.updated_at.desc(), Source.title.asc())


async def create_or_update_source(
    user: User,
    payload: SourceCreate,
    db: AsyncSession,
) -> Source:
    existing: Source | None = None
    if payload.external_id:
        result = await db.execute(
            select(Source).where(
                Source.user_id == user.id,
                Source.origin == payload.origin,
                Source.external_id == payload.external_id,
            )
        )
        existing = result.scalar_one_or_none()

    if existing:
        existing.source_type = payload.source_type
        existing.title = payload.title
        existing.source_url = payload.source_url
        existing.status = payload.status
        existing.import_error = payload.import_error
        existing.last_imported_at = datetime.now(UTC)
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
    await db.commit()
    await db.refresh(source)
    return source


async def update_source(source: Source, payload: SourceUpdate, db: AsyncSession) -> Source:
    update_data = payload.model_dump(exclude_unset=True)

    for field, value in update_data.items():
        setattr(source, field, value)

    await db.commit()
    await db.refresh(source)
    return source
