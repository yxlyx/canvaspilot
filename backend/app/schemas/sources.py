import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, field_validator

from app.models.source import SourceKind, SourceStatus


def normalize_topic_tags(tags: list[str]) -> list[str]:
    seen: set[str] = set()
    normalized: list[str] = []
    for tag in tags:
        value = tag.strip().lower()
        if not value or value in seen:
            continue
        seen.add(value)
        normalized.append(value)
    return normalized


class SourceCreate(BaseModel):
    source_type: SourceKind
    origin: str
    external_id: str | None = None
    title: str
    source_url: str = ""
    citation_label: str | None = None
    topic_tags: list[str] = []
    status: SourceStatus = SourceStatus.PENDING
    course_context: str | None = None
    project_context: str | None = None
    import_error: str | None = None

    @field_validator("origin", "title", "source_url", "citation_label", mode="before")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        if value is None:
            return value
        return value.strip()

    @field_validator(
        "external_id",
        "course_context",
        "project_context",
        "import_error",
        mode="before",
    )
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None

    @field_validator("topic_tags")
    @classmethod
    def normalize_tags(cls, value: list[str]) -> list[str]:
        return normalize_topic_tags(value)


class SourceUpdate(BaseModel):
    title: str | None = None
    source_url: str | None = None
    citation_label: str | None = None
    topic_tags: list[str] | None = None
    status: SourceStatus | None = None
    course_context: str | None = None
    project_context: str | None = None
    import_error: str | None = None

    @field_validator("title", "source_url", "citation_label", mode="before")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        if value is None:
            return value
        return value.strip()

    @field_validator("course_context", "project_context", "import_error", mode="before")
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None

    @field_validator("topic_tags")
    @classmethod
    def normalize_tags(cls, value: list[str] | None) -> list[str] | None:
        if value is None:
            return None
        return normalize_topic_tags(value)


class SourceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    source_type: SourceKind
    origin: str
    external_id: str | None
    title: str
    source_url: str
    citation_label: str
    topic_tags: list[str]
    status: SourceStatus
    course_context: str | None
    project_context: str | None
    last_imported_at: datetime | None
    import_error: str | None
    created_at: datetime
    updated_at: datetime
