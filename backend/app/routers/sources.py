import asyncio
import uuid

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from app.db.database import get_db
from app.dependencies import get_current_user
from app.exceptions import NotFoundError
from app.models.processing import SourceVersion
from app.models.source import Source, SourceKind, SourceStatus
from app.models.user import User
from app.schemas.sources import (
    SourceCreate,
    SourceIntakeRequest,
    SourceIntakeResponse,
    SourceResponse,
    SourceUpdate,
)
from app.services.processing import enqueue_source_version
from app.services.source_intake import ingest_source
from app.services.source_previews import (
    SourcePreviewUnavailableError,
    SourcePreviewUnsupportedError,
    render_source_preview,
)
from app.services.sources import build_source_list_statement, create_or_update_source, update_source

router = APIRouter(prefix="/sources", tags=["sources"])
_preview_slot = asyncio.Semaphore(1)
_preview_headers = {
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
}


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


@router.post(
    "/import",
    response_model=SourceIntakeResponse,
    status_code=status.HTTP_201_CREATED,
)
async def import_source(
    payload: SourceIntakeRequest,
    idempotency_key: str | None = Header(
        default=None, alias="Idempotency-Key", min_length=16, max_length=128
    ),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await ingest_source(user, payload, db, idempotency_key=idempotency_key)


@router.post("/{source_id}/versions", response_model=SourceIntakeResponse)
async def replace_source_content(
    source_id: uuid.UUID,
    payload: SourceIntakeRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    source = await db.scalar(
        select(Source).where(Source.id == source_id, Source.user_id == user.id)
    )
    if source is None:
        raise NotFoundError("Source not found")
    if source.source_type.value != payload.source_type:
        raise NotFoundError("Replacement source type must match the existing source")
    run = await enqueue_source_version(
        user,
        source,
        filename=payload.filename,
        content=payload.content,
        content_base64=payload.content_base64,
        source_url=str(payload.source_url) if payload.source_url else None,
        db=db,
    )
    await db.refresh(source)
    import_status = {
        "running": "running",
        "paused": "paused",
        "ready": "completed",
        "failed": "failed",
        "cancelled": "failed",
    }.get(run.status, "queued")
    return SourceIntakeResponse(
        source=source,
        job_id=run.id,
        import_status=import_status,
        duplicate=bool(getattr(run, "is_duplicate", False)),
    )


@router.get("/{source_id}/preview")
async def get_source_preview(
    source_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    try:
        parsed_source_id = uuid.UUID(source_id)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Source preview not found",
            headers=_preview_headers,
        ) from exc
    source = (
        await db.execute(
            select(Source.id, Source.source_type).where(
                Source.id == parsed_source_id,
                Source.user_id == user.id,
            )
        )
    ).one_or_none()
    if source is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Source preview not found",
            headers=_preview_headers,
        )
    try:
        async with asyncio.timeout(1):
            await _preview_slot.acquire()
    except TimeoutError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Preview capacity is temporarily busy",
            headers=_preview_headers,
        ) from exc
    try:
        version = await db.scalar(
            select(SourceVersion)
            .where(SourceVersion.source_id == source.id)
            .order_by(SourceVersion.version_number.desc())
            .limit(1)
        )
        if version is None:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Source preview not found",
                headers=_preview_headers,
            )
        preview = await run_in_threadpool(render_source_preview, source.source_type, version)
    except SourcePreviewUnsupportedError as exc:
        raise HTTPException(
            status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            detail=str(exc),
            headers=_preview_headers,
        ) from exc
    except SourcePreviewUnavailableError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
            headers=_preview_headers,
        ) from exc
    finally:
        _preview_slot.release()
    return Response(
        content=preview,
        media_type="image/png",
        headers=_preview_headers,
    )


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
