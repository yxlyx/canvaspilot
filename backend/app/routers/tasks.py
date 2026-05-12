from datetime import UTC

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.task import Task
from app.models.user import User
from app.schemas.tasks import TaskResponse

router = APIRouter(prefix="/tasks", tags=["tasks"])


@router.get("", response_model=list[TaskResponse])
async def list_tasks(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Task).where(Task.user_id == user.id).order_by(Task.due_at.asc())
    )
    return result.scalars().all()


@router.get("/upcoming", response_model=list[TaskResponse])
async def upcoming_tasks(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from datetime import datetime, timedelta

    now = datetime.now(UTC)
    cutoff = now + timedelta(days=14)
    result = await db.execute(
        select(Task)
        .where(Task.user_id == user.id, Task.due_at >= now, Task.due_at <= cutoff)
        .order_by(Task.due_at.asc())
    )
    return result.scalars().all()
