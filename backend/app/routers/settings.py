from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.settings import UserPreferenceResponse, UserPreferenceUpdateRequest
from app.services.preferences import get_preferences, update_preferences

router = APIRouter(prefix="/settings", tags=["settings"])


@router.get("/preferences", response_model=UserPreferenceResponse)
async def preferences(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    preference = await get_preferences(user, db)
    await db.commit()
    return preference


@router.patch("/preferences", response_model=UserPreferenceResponse)
async def save_preferences(
    payload: UserPreferenceUpdateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_preferences(user, payload, db)
