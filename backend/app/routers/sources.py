import uuid

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.exceptions import NotFoundError
from app.models.source import Source, SourceKind, SourceStatus
from app.models.user import User
from app.schemas.sources import SourceCreate, SourceResponse, SourceUpdate
from app.services.sources import build_source_list_statement, create_or_update_source, update_source

router = APIRouter(prefix="/sources", tags=["sources"])


@router.get("", response_model=list[SourceResponse])
async def list_sources(
    source_type: SourceKind | None = None,
    source_status: SourceStatus | None = Query(None, alias="status"),
    topic_tag: str | None = None,
    limit: int = Query(default=100, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        build_source_list_statement(
            user_id=user.id,
            source_type=source_type,
            status=source_status,
            topic_tag=topic_tag,
            limit=limit,
        )
    )
    return result.scalars().all()


@router.post("", response_model=SourceResponse, status_code=status.HTTP_201_CREATED)
async def create_source(
    payload: SourceCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    safe_payload = payload.model_copy(update={"status": SourceStatus.PENDING, "import_error": None})
    return await create_or_update_source(user, safe_payload, db)


@router.get("/{source_id}", response_model=SourceResponse)
async def get_source(
    source_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Source).where(Source.id == source_id, Source.user_id == user.id)
    )
    source = result.scalar_one_or_none()
    if not source:
        raise NotFoundError("Source not found")
    return source


@router.patch("/{source_id}", response_model=SourceResponse)
async def patch_source(
    source_id: uuid.UUID,
    payload: SourceUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Source).where(Source.id == source_id, Source.user_id == user.id)
    )
    source = result.scalar_one_or_none()
    if not source:
        raise NotFoundError("Source not found")
    return await update_source(source, payload, db)
