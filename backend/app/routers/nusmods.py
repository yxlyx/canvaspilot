import uuid
from collections.abc import AsyncGenerator

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.curriculum import (
    ImportCommitRequest,
    ImportCommitResponse,
    ImportPreviewRequest,
    ImportPreviewResponse,
)
from app.services.curriculum import commit_import_preview, create_import_preview
from app.services.nusmods import NUSModsClient

router = APIRouter(prefix="/nusmods/imports", tags=["nusmods"])


async def get_nusmods_client() -> AsyncGenerator[NUSModsClient, None]:
    async with NUSModsClient() as client:
        yield client


@router.post("/preview", response_model=ImportPreviewResponse, status_code=status.HTTP_201_CREATED)
async def preview_import(
    payload: ImportPreviewRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    client: NUSModsClient = Depends(get_nusmods_client),
):
    return await create_import_preview(
        user=user,
        academic_year=payload.academic_year,
        semester=payload.semester,
        share_url=payload.share_url,
        manual_codes=payload.module_codes,
        db=db,
        client=client,
    )


@router.post("/{preview_id}/commit", response_model=ImportCommitResponse)
async def commit_import(
    preview_id: uuid.UUID,
    payload: ImportCommitRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await commit_import_preview(
        preview_id=preview_id,
        selected_codes=payload.selected_codes,
        archive_codes=payload.archive_codes,
        user=user,
        db=db,
    )
