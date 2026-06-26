import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.schemas.sources import normalize_topic_tags


class FlashcardGenerateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_ids: list[uuid.UUID] | None = None
    source_chunk_ids: list[uuid.UUID] | None = None
    wiki_page_id: uuid.UUID | None = None
    topic: str | None = None
    deck_title: str | None = None
    limit: int = Field(default=10, ge=1, le=20)

    @field_validator("source_ids", "source_chunk_ids")
    @classmethod
    def deduplicate_ids(cls, value: list[uuid.UUID] | None) -> list[uuid.UUID] | None:
        if value is None:
            return None
        if not value:
            raise ValueError("At least one id is required when a selection list is provided")
        seen: set[uuid.UUID] = set()
        ordered: list[uuid.UUID] = []
        for selected_id in value:
            if selected_id in seen:
                continue
            seen.add(selected_id)
            ordered.append(selected_id)
        return ordered

    @field_validator("topic", "deck_title", mode="before")
    @classmethod
    def strip_optional_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None

    @field_validator("topic")
    @classmethod
    def normalize_topic(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = normalize_topic_tags([value])
        return normalized[0] if normalized else None

    @model_validator(mode="after")
    def require_single_generation_scope(self):
        scopes = [
            self.source_ids is not None,
            self.source_chunk_ids is not None,
            self.wiki_page_id is not None,
            self.topic is not None,
        ]
        if sum(scopes) != 1:
            raise ValueError("Choose exactly one flashcard generation scope")
        return self


class FlashcardAttemptCreate(BaseModel):
    answer_text: str = ""
    is_correct: bool
    confidence: int | None = Field(default=None, ge=1, le=5)

    @field_validator("answer_text", mode="before")
    @classmethod
    def strip_answer_text(cls, value: str | None) -> str:
        if value is None:
            return ""
        return value.strip()


class LearningEvidenceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    evidence_type: str
    topic_tag: str
    source_id: uuid.UUID | None
    source_chunk_id: uuid.UUID | None
    wiki_page_id: uuid.UUID | None
    flashcard_id: uuid.UUID | None
    flashcard_attempt_id: uuid.UUID | None
    is_correct: bool | None
    confidence: int | None
    citation_ref: str
    occurred_at: datetime


class FlashcardResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    deck_id: uuid.UUID
    user_id: uuid.UUID
    source_id: uuid.UUID | None
    source_chunk_id: uuid.UUID | None
    wiki_page_id: uuid.UUID | None
    order_index: int
    card_type: str
    question: str
    answer: str
    topic_tag: str
    citation_ref: str
    source_title: str
    location_label: str
    created_at: datetime
    updated_at: datetime


class FlashcardDeckResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    title: str
    description: str
    generation_scope: str
    source_ids: list[uuid.UUID]
    wiki_page_id: uuid.UUID | None
    topic_tags: list[str]
    card_count: int
    cards: list[FlashcardResponse] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime


class FlashcardAttemptResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    deck_id: uuid.UUID
    card_id: uuid.UUID
    answer_text: str
    is_correct: bool
    confidence: int | None
    evidence: LearningEvidenceResponse | None = None
    created_at: datetime


class FlashcardGenerateResponse(BaseModel):
    deck: FlashcardDeckResponse | None = None
    generated_count: int
    message: str
