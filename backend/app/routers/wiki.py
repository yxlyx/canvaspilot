from fastapi import APIRouter, Body, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.wiki import WikiCompileRequest, WikiCompileResponse, WikiPageResponse
from app.services.wiki import compile_workspace_wiki, get_wiki_page, list_wiki_pages

router = APIRouter(prefix="/wiki", tags=["wiki"])


@router.post("/compile", response_model=WikiCompileResponse)
async def compile_wiki(
    payload: WikiCompileRequest | None = Body(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    source_ids = payload.source_ids if payload is not None else None
    pages = await compile_workspace_wiki(user, db, source_ids)
    return WikiCompileResponse(pages=pages)


@router.get("/pages", response_model=list[WikiPageResponse])
async def list_pages(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_wiki_pages(user, db)


@router.get("/pages/{slug}", response_model=WikiPageResponse)
async def get_page(
    slug: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_wiki_page(user, slug, db)
