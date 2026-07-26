import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.schemas.sources import normalize_topic_tags


class FlashcardGenerateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enrollment_id: uuid.UUID | None = None
    topic_ids: list[uuid.UUID] | None = None
    source_ids: list[uuid.UUID] | None = None
    source_chunk_ids: list[uuid.UUID] | None = None
    wiki_page_id: uuid.UUID | None = None
    topic: str | None = None
    deck_title: str | None = None
    limit: int = Field(default=10, ge=1, le=20)
    regenerate: bool = False

    @field_validator("source_ids", "source_chunk_ids", "topic_ids")
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
            self.enrollment_id is not None,
            self.topic_ids is not None,
            self.source_ids is not None,
            self.source_chunk_ids is not None,
            self.wiki_page_id is not None,
            self.topic is not None,
        ]
        if sum(scopes) != 1:
            raise ValueError("Choose exactly one flashcard generation scope")
        return self


class GeneratedFlashcardWording(BaseModel):
    model_config = ConfigDict(extra="forbid")

    evidence_key: str = Field(pattern=r"^E[1-9][0-9]*$")
    question: str = Field(min_length=8, max_length=500)
    answer: str = Field(min_length=1, max_length=1000)
    support_quote: str = Field(min_length=1, max_length=1000)
    card_type: Literal[
        "definition",
        "concept_check",
        "comparison",
        "procedure",
        "complexity",
        "misconception",
    ]

    @field_validator("question", "answer", "support_quote", mode="before")
    @classmethod
    def strip_generated_text(cls, value: str) -> str:
        return value.strip()


class GeneratedFlashcardBatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    cards: list[GeneratedFlashcardWording] = Field(min_length=1, max_length=20)

    @model_validator(mode="after")
    def unique_evidence_keys(self):
        keys = [card.evidence_key for card in self.cards]
        if len(keys) != len(set(keys)):
            raise ValueError("Each evidence key may be used only once")
        return self


class DraftDeckUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_revision: int = Field(ge=1)
    title: str = Field(min_length=1, max_length=1000)

    @field_validator("title")
    @classmethod
    def strip_title(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("Title is required")
        return value.strip()


class CitationSelection(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_id: uuid.UUID
    source_chunk_id: uuid.UUID | None = None
    wiki_page_id: uuid.UUID | None = None


class DraftCardUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_revision: int = Field(ge=1)
    question: str | None = Field(default=None, min_length=1)
    answer: str | None = Field(default=None, min_length=1)
    tags: list[str] | None = None
    topic_ids: list[uuid.UUID] | None = None
    citations: list[CitationSelection] | None = None
    manual_note: bool | None = None


class DraftCardAdd(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_revision: int = Field(ge=1)
    question: str = Field(min_length=1)
    answer: str = Field(min_length=1)
    tags: list[str] = Field(default_factory=list)
    topic_ids: list[uuid.UUID] = Field(default_factory=list)
    citations: list[CitationSelection] = Field(default_factory=list)
    manual_note: bool = False


class DraftReorder(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_revision: int = Field(ge=1)
    card_ids: list[uuid.UUID]


class DraftAction(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_revision: int = Field(ge=1)
    card_ids: list[uuid.UUID] | None = None


class DiscardAction(DraftAction):
    rejection_reason: str

    @field_validator("rejection_reason")
    @classmethod
    def valid_rejection_reason(cls, value: str) -> str:
        allowed = {
            "too_generic",
            "ambiguous_answer",
            "wrong_concept",
            "poor_evidence",
            "duplicate",
            "other",
        }
        if value not in allowed:
            raise ValueError("Choose a supported flashcard rejection reason")
        return value


class FlashcardAttemptCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    rating: str | None = None
    answer_text: str = ""
    is_correct: bool | None = None
    confidence: int | None = Field(default=None, ge=1, le=5)

    @field_validator("rating")
    @classmethod
    def valid_rating(cls, value: str | None) -> str | None:
        if value is not None and value not in {"Again", "Hard", "Good", "Easy"}:
            raise ValueError("Rating must be Again, Hard, Good, or Easy")
        return value

    @model_validator(mode="after")
    def require_rating_or_legacy_result(self):
        if self.rating is None and self.is_correct is None:
            raise ValueError("rating is required")
        return self

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
    topic_ids: list[uuid.UUID]
    tags: list[str]
    citation_ref: str
    citations: list[dict]
    source_title: str
    location_label: str
    state: str
    manual_note: bool
    approved: bool
    created_at: datetime
    updated_at: datetime


class FlashcardRevisionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    deck_id: uuid.UUID
    user_id: uuid.UUID
    revision: int
    action: str
    before: dict
    after: dict
    created_at: datetime


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
    lifecycle: str
    revision: int
    input_fingerprint: str | None
    scope_snapshot: dict
    generator_snapshot: dict
    enrollment_id: uuid.UUID | None
    topic_ids: list[uuid.UUID]
    predecessor_id: uuid.UUID | None
    approved_at: datetime | None
    retired_at: datetime | None
    approved_snapshot: dict | None
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
    rating: str
    ease: int
    is_correct: bool
    confidence: int | None
    evidence: LearningEvidenceResponse | None = None
    created_at: datetime


class FlashcardGenerateResponse(BaseModel):
    deck: FlashcardDeckResponse | None = None
    generated_count: int
    message: str
