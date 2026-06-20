import uuid

from pydantic import BaseModel, field_validator


class SourceImportItem(BaseModel):
    source_id: uuid.UUID
    content: str

    @field_validator("content")
    @classmethod
    def strip_content(cls, value: str) -> str:
        return value.strip()


class SourceImportRun(BaseModel):
    sources: list[SourceImportItem]

    @field_validator("sources")
    @classmethod
    def require_sources(cls, value: list[SourceImportItem]) -> list[SourceImportItem]:
        if not value:
            raise ValueError("At least one source import is required")
        seen: set[uuid.UUID] = set()
        for item in value:
            if item.source_id in seen:
                raise ValueError("Duplicate source import")
            seen.add(item.source_id)
        return value
