import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError
from app.models.module import Module
from app.models.settings import UserPreference
from app.models.user import User
from app.schemas.settings import UserPreferenceUpdateRequest


async def get_preferences(user: User, db: AsyncSession) -> UserPreference:
    return await get_preferences_by_user_id(user.id, db)


async def get_preferences_by_user_id(user_id: uuid.UUID, db: AsyncSession) -> UserPreference:
    preferences = await db.get(UserPreference, user_id)
    if preferences is None:
        preferences = UserPreference(user_id=user_id)
        db.add(preferences)
        await db.flush()
        await db.refresh(preferences)
    return preferences


async def update_preferences(
    user: User, payload: UserPreferenceUpdateRequest, db: AsyncSession
) -> UserPreference:
    preferences = await get_preferences(user, db)
    values = payload.model_dump(exclude_unset=True)
    module_id: uuid.UUID | None = values.get("default_module_id")
    if module_id is not None:
        owned = await db.scalar(
            select(Module.id).where(Module.id == module_id, Module.user_id == user.id)
        )
        if owned is None:
            raise NotFoundError("Default module not found")
    for field, value in values.items():
        setattr(preferences, field, value)
    await db.commit()
    await db.refresh(preferences)
    return preferences
