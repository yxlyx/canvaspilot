import uuid

from fastapi import APIRouter, Depends, Header, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.processing import (
    ManualTriggerRequest,
    ProcessingPolicyResponse,
    ProcessingPolicyUpdate,
    ProcessingRunResponse,
    RetryRunRequest,
)
from app.services.processing import (
    cancel_run,
    get_processing_policy,
    get_run,
    list_runs,
    retry_run,
    trigger_source_rebuild,
    update_processing_policy,
)

router = APIRouter(prefix="/processing", tags=["processing"])


@router.get("/runs", response_model=list[ProcessingRunResponse])
async def processing_runs(
    source_id: uuid.UUID | None = None,
    latest_per_source: bool = False,
    limit: int = Query(default=100, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_runs(
        user,
        db,
        source_id=source_id,
        limit=limit,
        latest_per_source=latest_per_source,
    )


@router.get("/runs/{run_id}", response_model=ProcessingRunResponse)
async def processing_run(
    run_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_run(user, run_id, db)


@router.post("/runs/{run_id}/retry", response_model=ProcessingRunResponse)
async def retry_processing_run(
    run_id: uuid.UUID,
    payload: RetryRunRequest | None = None,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await retry_run(
        user,
        run_id,
        db,
        from_stage=payload.from_stage if payload is not None else None,
    )


@router.post("/runs/{run_id}/cancel", response_model=ProcessingRunResponse)
async def cancel_processing_run(
    run_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await cancel_run(user, run_id, db)


@router.post(
    "/trigger",
    response_model=ProcessingRunResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def trigger_processing_run(
    payload: ManualTriggerRequest,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=16, max_length=128),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await trigger_source_rebuild(
        user,
        payload.source_id,
        db,
        idempotency_key=idempotency_key,
    )


@router.get("/policy", response_model=ProcessingPolicyResponse)
async def processing_policy(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    policy = await get_processing_policy(user.id, db)
    await db.commit()
    return policy


@router.patch("/policy", response_model=ProcessingPolicyResponse)
async def save_processing_policy(
    payload: ProcessingPolicyUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_processing_policy(user, payload, db)
