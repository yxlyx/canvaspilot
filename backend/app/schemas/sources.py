import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, field_validator, model_validator

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
    enrollment_id: uuid.UUID | None = None
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
    enrollment_id: uuid.UUID | None = None
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
    enrollment_id: uuid.UUID | None = None
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


class SourceIntakeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    mode: Literal["upload", "link", "paste"]
    title: str = Field(min_length=1, max_length=1000)
    enrollment_id: uuid.UUID | None = None
    course_context: str | None = Field(default=None, max_length=255)
    source_type: Literal["pdf", "image", "markdown", "plain_text", "link"]
    filename: str | None = Field(default=None, max_length=255)
    source_url: HttpUrl | None = Field(default=None, max_length=2048)
    content: str | None = Field(default=None, max_length=2_000_000)
    content_base64: str | None = Field(default=None, max_length=14_000_000)

    @field_validator("title", "course_context", "filename", "content", mode="before")
    @classmethod
    def strip_intake_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None

    @model_validator(mode="after")
    def validate_mode_payload(self):
        if self.mode == "link":
            if self.source_type != "link" or self.source_url is None:
                raise ValueError("A valid public link is required")
        elif self.mode == "paste":
            if self.source_type not in {"markdown", "plain_text"} or not self.content:
                raise ValueError("Pasted Markdown or plain text is required")
        elif self.mode == "upload":
            if self.source_type in {"pdf", "image"}:
                if not self.filename or not self.content_base64:
                    raise ValueError("A PDF or image file is required")
            elif self.source_type in {"markdown", "plain_text"}:
                if not self.filename or not self.content:
                    raise ValueError("A Markdown or text file is required")
            else:
                raise ValueError("Upload a PDF, PNG, JPEG, Markdown, or text file")
        return self


class SourceIntakeResponse(BaseModel):
    source: SourceResponse
    job_id: uuid.UUID | None = None
    import_status: Literal["saved", "queued", "running", "paused", "completed", "failed"]
    duplicate: bool = False
