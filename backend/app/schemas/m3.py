import uuid
from datetime import datetime
from typing import Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    HttpUrl,
    field_validator,
    model_validator,
)

from app.schemas.sources import normalize_topic_tags

MAX_SELECTION = 12
MAX_MARKED_PAPER_BASE64 = 14_000_000


class StudyOutputGenerateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    output_type: Literal["summary", "outline", "study_guide"] = "summary"
    title: str | None = Field(default=None, max_length=300)
    source_ids: list[uuid.UUID] | None = Field(default=None, max_length=MAX_SELECTION)
    source_chunk_ids: list[uuid.UUID] | None = Field(default=None, max_length=MAX_SELECTION)
    wiki_page_id: uuid.UUID | None = None
    topic: str | None = Field(default=None, max_length=100)

    @field_validator("topic")
    @classmethod
    def normalize_topic(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip().lower()
        if not normalized:
            raise ValueError("topic cannot be empty")
        return normalized

    @model_validator(mode="after")
    def require_one_scope(self):
        if (
            sum(
                value is not None
                for value in (self.source_ids, self.source_chunk_ids, self.wiki_page_id, self.topic)
            )
            != 1
        ):
            raise ValueError("Choose exactly one generation scope")
        if self.source_ids == [] or self.source_chunk_ids == []:
            raise ValueError("Selection cannot be empty")
        return self


class StudyOutputCitationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    source_id: uuid.UUID
    source_chunk_id: uuid.UUID | None
    citation_key: str
    citation_ref: str
    source_title: str
    snippet: str


class StudyOutputResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    output_type: str
    title: str
    status: str
    content: str
    source_ids: list[uuid.UUID]
    wiki_page_id: uuid.UUID | None
    message: str
    citations: list[StudyOutputCitationResponse] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class WikiRevisionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    page_id: uuid.UUID
    revision_number: int
    title: str
    markdown: str
    source_ids: list[uuid.UUID]
    citation_count: int
    change_summary: str
    created_at: datetime


class RevisionDiffResponse(BaseModel):
    page_id: uuid.UUID
    from_revision: int
    to_revision: int
    diff: str


class SourceChangeResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    source_id: uuid.UUID
    change_type: str
    before_snapshot: dict
    after_snapshot: dict
    created_at: datetime


class HistoryEntryResponse(BaseModel):
    id: uuid.UUID
    entry_type: str
    resource_id: uuid.UUID
    summary: str
    created_at: datetime


class HealthFindingResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    code: str
    severity: Literal["info", "warning", "error"]
    state: Literal["healthy", "warning", "stale", "failed", "unknown"]
    resource_type: str
    resource_id: uuid.UUID | None
    topic: str | None = None
    message: str
    recommendation: str
    created_at: datetime


class WorkspaceExportRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    page_ids: list[uuid.UUID] = Field(min_length=1, max_length=100)

    @field_validator("page_ids")
    @classmethod
    def unique_pages(cls, value: list[uuid.UUID]) -> list[uuid.UUID]:
        if len(value) != len(set(value)):
            raise ValueError("Duplicate wiki page selection")
        return value


class MeterSignal(BaseModel):
    name: str
    value: float | None
    evidence_count: int


class TopicMeterResponse(BaseModel):
    topic: str
    estimated_completion: float | None
    evidence_confidence: float
    evidence_count: int
    state: Literal["measured", "uncertain", "stale"]
    stale: bool
    signals: list[MeterSignal]
    recommendation: str


class MutationAck(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID


class MutationResult(BaseModel):
    ok: bool = True


class MarkedPaperUploadRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    filename: str = Field(min_length=1, max_length=255)
    content_type: Literal["text/plain", "text/markdown", "application/pdf"]
    content_base64: str = Field(min_length=1, max_length=MAX_MARKED_PAPER_BASE64)

    @field_validator("filename")
    @classmethod
    def safe_filename(cls, value: str) -> str:
        value = value.strip()
        if not value or value != value.split("/")[-1] or "\\" in value:
            raise ValueError("filename must not contain a path")
        return value


class MarkedPaperQuestionCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    question_number: int = Field(ge=1, le=100_000)
    question_text: str = Field(min_length=1, max_length=20_000)
    awarded_marks: float | None = Field(default=None, ge=0, le=10_000)
    available_marks: float | None = Field(default=None, gt=0, le=10_000)
    feedback: str = Field(default="", max_length=10_000)
    topic_tag: str = Field(default="general", min_length=1, max_length=100)
    confidence: float = Field(default=0.5, ge=0, le=1)
    reviewed: bool = False

    @field_validator("topic_tag")
    @classmethod
    def normalize_topic(cls, value: str) -> str:
        normalized = normalize_topic_tags([value])
        if not normalized:
            raise ValueError("topic_tag must not be blank")
        return normalized[0]


class MarkedPaperQuestionUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    question_text: str | None = Field(default=None, min_length=1, max_length=20_000)
    awarded_marks: float | None = Field(default=None, ge=0, le=10_000)
    available_marks: float | None = Field(default=None, gt=0, le=10_000)
    feedback: str | None = Field(default=None, max_length=10_000)
    topic_tag: str | None = Field(default=None, min_length=1, max_length=100)
    confidence: float | None = Field(default=None, ge=0, le=1)
    reviewed: bool | None = None

    @field_validator("topic_tag")
    @classmethod
    def normalize_topic(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = normalize_topic_tags([value])
        if not normalized:
            raise ValueError("topic_tag must not be blank")
        return normalized[0]

    @model_validator(mode="after")
    def reject_null_non_nullable_fields(self):
        non_nullable = {
            "question_text",
            "feedback",
            "topic_tag",
            "confidence",
            "reviewed",
        }
        invalid = sorted(
            field
            for field in non_nullable.intersection(self.model_fields_set)
            if getattr(self, field) is None
        )
        if invalid:
            raise ValueError(f"Fields cannot be null: {', '.join(invalid)}")
        return self


class MarkedPaperQuestionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    question_number: int
    question_text: str
    awarded_marks: float | None
    available_marks: float | None
    feedback: str
    topic_tag: str
    confidence: float
    reviewed: bool
    reviewed_at: datetime | None


class MarkedPaperResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    filename: str
    content_type: str
    extraction_status: str
    extraction_message: str
    questions: list[MarkedPaperQuestionResponse] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class StudyOutputPageResponse(BaseModel):
    items: list[StudyOutputResponse]
    next_cursor: str | None


class MarkedPaperPageResponse(BaseModel):
    items: list[MarkedPaperResponse]
    next_cursor: str | None


class ProviderDescriptor(BaseModel):
    id: str
    name: str
    models: list[str]
    endpoint: str


class ProviderConfigureRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    provider: Literal["openai", "openai_compatible", "azure_openai", "google_gemini"]
    api_key: str = Field(min_length=8, max_length=4096)
    model: str = Field(min_length=1, max_length=100)
    endpoint: HttpUrl | None = Field(default=None, max_length=500)


class ProviderStatusResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    provider: str
    model: str
    endpoint: str
    status: str
    credential: str = "********"
    last_tested_at: datetime | None
    updated_at: datetime
