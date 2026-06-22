import uuid

from pydantic import BaseModel, field_validator


class SourceImportSection(BaseModel):
    content: str
    citation_ref: str | None = None
    location_label: str = ""

    @field_validator("content", "citation_ref", "location_label", mode="before")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        if value is None:
            return value
        return value.strip()


class SourceImportItem(BaseModel):
    source_id: uuid.UUID
    content: str = ""
    citation_ref: str | None = None
    location_label: str = ""
    sections: list[SourceImportSection] = []
    metadata_only: bool = False
    import_error: str | None = None

    @field_validator("content", "citation_ref", "location_label", "import_error", mode="before")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        if value is None:
            return value
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


class SourceParseItem(BaseModel):
    source_id: uuid.UUID
    filename: str | None = None
    content: str | None = None
    content_base64: str | None = None
    source_url: str | None = None

    @field_validator("filename", "content", "content_base64", "source_url", mode="before")
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None


class SourceParseRun(BaseModel):
    sources: list[SourceParseItem]

    @field_validator("sources")
    @classmethod
    def require_sources(cls, value: list[SourceParseItem]) -> list[SourceParseItem]:
        if not value:
            raise ValueError("At least one source import is required")
        seen: set[uuid.UUID] = set()
        for item in value:
            if item.source_id in seen:
                raise ValueError("Duplicate source import")
            seen.add(item.source_id)
        return value
