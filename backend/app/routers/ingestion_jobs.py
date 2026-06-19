import uuid

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.ingestion_job import IngestionJobStatus
from app.models.user import User
from app.schemas.ingestion_jobs import IngestionJobCreate, IngestionJobResponse
from app.services.ingestion_jobs import (
    build_ingestion_job_list_statement,
    create_queued_ingestion_job,
    get_owned_ingestion_job,
)

router = APIRouter(prefix="/ingestion/jobs", tags=["ingestion"])


@router.post("", response_model=IngestionJobResponse, status_code=status.HTTP_201_CREATED)
async def create_ingestion_job(
    payload: IngestionJobCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await create_queued_ingestion_job(user, payload.source_ids, db)


@router.get("", response_model=list[IngestionJobResponse])
async def list_ingestion_jobs(
    job_status: IngestionJobStatus | None = Query(None, alias="status"),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        build_ingestion_job_list_statement(
            user_id=user.id,
            status=job_status,
        )
    )
    return result.scalars().all()


@router.get("/{job_id}", response_model=IngestionJobResponse)
async def get_ingestion_job(
    job_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_owned_ingestion_job(user, job_id, db)
