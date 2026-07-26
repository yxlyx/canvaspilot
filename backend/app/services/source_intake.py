import hashlib

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.source import SourceStatus
from app.models.user import User
from app.schemas.sources import SourceCreate, SourceIntakeRequest, SourceIntakeResponse
from app.services.processing import enqueue_source_version
from app.services.sources import create_or_update_source


def _identity(payload: SourceIntakeRequest) -> tuple[str, str]:
    if payload.mode == "link":
        value = str(payload.source_url).strip().rstrip("/")
        return "web", hashlib.sha256(value.encode()).hexdigest()
    if payload.source_type in {"pdf", "image"}:
        value = payload.content_base64 or ""
    else:
        value = payload.content or ""
    return "upload", hashlib.sha256(value.encode()).hexdigest()


async def ingest_source(
    user: User,
    payload: SourceIntakeRequest,
    db: AsyncSession,
    *,
    idempotency_key: str | None = None,
) -> SourceIntakeResponse:
    origin, external_id = _identity(payload)
    source = await create_or_update_source(
        user,
        SourceCreate(
            enrollment_id=payload.enrollment_id,
            source_type=payload.source_type,
            origin=origin,
            external_id=external_id,
            title=payload.title,
            source_url=str(payload.source_url) if payload.source_url else "",
            citation_label=payload.title,
            course_context=payload.course_context,
            status=SourceStatus.PENDING,
        ),
        db,
    )
    if payload.mode == "link":
        return SourceIntakeResponse(
            source=source,
            job_id=None,
            import_status="saved",
            duplicate=False,
        )
    run = await enqueue_source_version(
        user,
        source,
        filename=payload.filename,
        content=payload.content,
        content_base64=payload.content_base64,
        source_url=str(payload.source_url) if payload.source_url else None,
        db=db,
        idempotency_key=idempotency_key,
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
