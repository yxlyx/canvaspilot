import uuid
from datetime import datetime

from pydantic import BaseModel


class WorkspaceSearchResult(BaseModel):
    result_type: str
    title: str
    source_type: str
    snippet: str
    score: float
    citation_ref: str | None = None
    source_id: uuid.UUID | None = None
    source_chunk_id: uuid.UUID | None = None
    content_chunk_id: uuid.UUID | None = None
    wiki_page_id: uuid.UUID | None = None
    wiki_slug: str | None = None
    url: str = ""
    updated_at: datetime


class WorkspaceSearchResponse(BaseModel):
    query: str
    results: list[WorkspaceSearchResult]
