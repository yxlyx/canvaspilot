import uuid

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError
from app.models.curriculum import ModuleEnrollment
from app.models.module import Module
from app.models.settings import UserPreference
from app.models.user import User
from app.schemas.settings import UserPreferenceUpdateRequest


async def get_preferences(user: User, db: AsyncSession) -> UserPreference:
    return await get_preferences_by_user_id(user.id, db)


async def get_preferences_by_user_id(user_id: uuid.UUID, db: AsyncSession) -> UserPreference:
    await db.execute(
        insert(UserPreference)
        .values(user_id=user_id)
        .on_conflict_do_nothing(index_elements=[UserPreference.user_id])
    )
    preferences = await db.scalar(select(UserPreference).where(UserPreference.user_id == user_id))
    if preferences is None:
        raise RuntimeError("preference insert did not return the stored row")
    return preferences


async def update_preferences(
    user: User, payload: UserPreferenceUpdateRequest, db: AsyncSession
) -> UserPreference:
    preferences = await get_preferences(user, db)
    values = payload.model_dump(exclude_unset=True)
    module_id: uuid.UUID | None = values.get("default_module_id")
    enrollment_id: uuid.UUID | None = values.get("default_enrollment_id")
    if module_id is not None:
        owned = await db.scalar(
            select(Module.id).where(Module.id == module_id, Module.user_id == user.id)
        )
        if owned is None:
            raise NotFoundError("Default module not found")
    if enrollment_id is not None:
        owned = await db.scalar(
            select(ModuleEnrollment.id).where(
                ModuleEnrollment.id == enrollment_id,
                ModuleEnrollment.user_id == user.id,
                ModuleEnrollment.archived.is_(False),
            )
        )
        if owned is None:
            raise NotFoundError("Default enrollment not found")
    if "default_module_id" in values and "default_enrollment_id" not in values:
        values["default_enrollment_id"] = None
    if "default_enrollment_id" in values and "default_module_id" not in values:
        values["default_module_id"] = None
    for field, value in values.items():
        setattr(preferences, field, value)
    await db.commit()
    await db.refresh(preferences)
    return preferences
