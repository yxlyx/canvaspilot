import uuid

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.exceptions import NotFoundError
from app.models.module import Module
from app.models.user import User
from app.schemas.modules import AnnouncementResponse, ModuleResponse

router = APIRouter(prefix="/modules", tags=["modules"])


@router.get("", response_model=list[ModuleResponse])
async def list_modules(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Module).where(Module.user_id == user.id))
    return result.scalars().all()


@router.get("/{module_id}", response_model=ModuleResponse)
async def get_module(
    module_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Module).where(Module.id == module_id, Module.user_id == user.id)
    )
    module = result.scalar_one_or_none()
    if not module:
        raise NotFoundError("Module not found")
    return module


@router.get("/{module_id}/announcements", response_model=list[AnnouncementResponse])
async def get_announcements(
    module_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Module).where(Module.id == module_id, Module.user_id == user.id)
    )
    module = result.scalar_one_or_none()
    if not module:
        raise NotFoundError("Module not found")
    return [
        AnnouncementResponse(
            id=a.id,
            module_id=a.module_id,
            title=a.title,
            content=a.content_text,
            posted_at=a.posted_at,
            summary=a.summary,
        )
        for a in module.announcements
    ]
