import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator


class WikiCompileRequest(BaseModel):
    source_ids: list[uuid.UUID] | None = Field(default=None, max_length=100)

    @field_validator("source_ids")
    @classmethod
    def deduplicate_source_ids(cls, value: list[uuid.UUID] | None) -> list[uuid.UUID] | None:
        if value is None:
            return None
        if not value:
            raise ValueError("At least one source is required when source_ids is provided")
        seen: set[uuid.UUID] = set()
        ordered: list[uuid.UUID] = []
        for source_id in value:
            if source_id in seen:
                continue
            seen.add(source_id)
            ordered.append(source_id)
        return ordered


class WikiCitationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    page_id: uuid.UUID
    source_id: uuid.UUID
    source_chunk_id: uuid.UUID | None
    citation_key: str
    citation_ref: str
    source_title: str
    location_label: str
    chunk_index: int | None
    snippet: str
    created_at: datetime


class WikiPageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    slug: str
    title: str
    page_type: str
    markdown: str
    summary: str
    source_ids: list[uuid.UUID]
    citation_count: int
    backlinks: list[str]
    citations: list[WikiCitationResponse] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class WikiCompileResponse(BaseModel):
    pages: list[WikiPageResponse]
