import uuid

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.settings import (
    NotificationCountResponse,
    NotificationPageResponse,
    NotificationResponse,
)
from app.services.notifications import (
    list_notifications,
    mark_all_notifications_read,
    mark_notification_read,
)

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("", response_model=NotificationPageResponse)
async def notifications(
    state: str = Query(default="all", pattern="^(all|unread)$"),
    limit: int = Query(default=50, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    items, unread_count = await list_notifications(user, db, state == "unread", limit)
    return {"items": items, "unread_count": unread_count}


@router.get("/unread-count", response_model=NotificationCountResponse)
async def unread_count(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    _, count = await list_notifications(user, db, True, 1)
    return {"unread_count": count}


@router.post("/{notification_id}/read", response_model=NotificationResponse)
async def read_notification(
    notification_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await mark_notification_read(user, notification_id, db)


@router.post("/read-all", status_code=status.HTTP_204_NO_CONTENT)
async def read_all(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    await mark_all_notifications_read(user, db)
