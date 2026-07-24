from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.settings import ActivityEntryResponse
from app.services.activity import activity_entries

router = APIRouter(prefix="/wiki/activity", tags=["wiki"])


@router.get("", response_model=list[ActivityEntryResponse])
async def wiki_activity(
    limit: int = Query(default=50, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await activity_entries(user, db, limit)
