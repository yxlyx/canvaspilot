import uuid

from pydantic import BaseModel, ConfigDict, Field, field_validator

MAX_IMPORT_SOURCES = 25
MAX_IMPORT_SECTIONS = 200
MAX_TEXT_CHARS = 2_000_000
MAX_FILE_BASE64_CHARS = 14_000_000
MAX_IMPORT_TEXT_CHARS = 4_000_000
MAX_PARSE_BASE64_CHARS = 14_000_000


class SourceImportSection(BaseModel):
    model_config = ConfigDict(extra="forbid")

    content: str = Field(max_length=MAX_TEXT_CHARS)
    citation_ref: str | None = Field(default=None, max_length=1_000)
    location_label: str = Field(default="", max_length=255)

    @field_validator("content", "citation_ref", "location_label", mode="before")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        if value is None:
            return value
        return value.strip()


class SourceImportItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_id: uuid.UUID
    content: str = Field(default="", max_length=MAX_TEXT_CHARS)
    citation_ref: str | None = Field(default=None, max_length=1_000)
    location_label: str = Field(default="", max_length=255)
    sections: list[SourceImportSection] = Field(
        default_factory=list, max_length=MAX_IMPORT_SECTIONS
    )
    metadata_only: bool = False
    import_error: str | None = Field(default=None, max_length=2_000)

    @field_validator("content", "citation_ref", "location_label", "import_error", mode="before")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        if value is None:
            return value
        return value.strip()


class SourceImportRun(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sources: list[SourceImportItem] = Field(max_length=MAX_IMPORT_SOURCES)

    @field_validator("sources")
    @classmethod
    def require_sources(cls, value: list[SourceImportItem]) -> list[SourceImportItem]:
        if not value:
            raise ValueError("At least one source import is required")
        if len({item.source_id for item in value}) != len(value):
            raise ValueError("Duplicate source import")
        total = sum(
            len(item.content) + sum(len(section.content) for section in item.sections)
            for item in value
        )
        if total > MAX_IMPORT_TEXT_CHARS:
            raise ValueError("Aggregate import text exceeds 4,000,000 characters")
        return value


class SourceParseItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_id: uuid.UUID
    filename: str | None = Field(default=None, max_length=255)
    content: str | None = Field(default=None, max_length=MAX_TEXT_CHARS)
    content_base64: str | None = Field(default=None, max_length=MAX_FILE_BASE64_CHARS)
    source_url: str | None = Field(default=None, max_length=2_048)

    @field_validator("filename", "content", "content_base64", "source_url", mode="before")
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None


class SourceParseRun(BaseModel):
    model_config = ConfigDict(extra="forbid")

    sources: list[SourceParseItem] = Field(max_length=MAX_IMPORT_SOURCES)

    @field_validator("sources")
    @classmethod
    def require_sources(cls, value: list[SourceParseItem]) -> list[SourceParseItem]:
        if not value:
            raise ValueError("At least one source import is required")
        if len({item.source_id for item in value}) != len(value):
            raise ValueError("Duplicate source import")
        text_total = sum(len(item.content or "") for item in value)
        base64_total = sum(len(item.content_base64 or "") for item in value)
        if text_total > MAX_IMPORT_TEXT_CHARS:
            raise ValueError("Aggregate parse text exceeds 4,000,000 characters")
        if base64_total > MAX_PARSE_BASE64_CHARS:
            raise ValueError("Aggregate encoded files exceed 14,000,000 characters")
        return value
