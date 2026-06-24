from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.search import WorkspaceSearchResponse
from app.services.search import SEARCH_LIMIT, search_workspace

router = APIRouter(prefix="/search", tags=["search"])


@router.get("", response_model=WorkspaceSearchResponse)
async def search(
    query: str = Query(..., min_length=1),
    limit: int = Query(SEARCH_LIMIT, ge=1, le=50),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    cleaned_query = " ".join(query.strip().split())
    if not cleaned_query:
        raise HTTPException(status_code=422, detail="Search query cannot be blank")
    results = await search_workspace(cleaned_query, user.id, db, limit)
    return WorkspaceSearchResponse(query=cleaned_query, results=results)
