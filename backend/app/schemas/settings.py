import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


class ProfileUpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=255)


class PasswordChangeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    current_password: str = Field(min_length=1, max_length=4096)
    new_password: str = Field(min_length=8, max_length=4096)


class PasswordConfirmationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    current_password: str = Field(min_length=1, max_length=4096)


class AccountDeleteRequest(PasswordConfirmationRequest):
    confirmation: Literal["DELETE"]


class UserPreferenceResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    theme: Literal["system", "light", "dark"]
    motion_preference: Literal["system", "reduce"]
    default_module_id: uuid.UUID | None
    daily_review_target: int
    reminder_daily_review: bool
    reminder_processing_attention: bool
    reminder_paper_review: bool
    reminder_health_attention: bool
    updated_at: datetime


class UserPreferenceUpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    theme: Literal["system", "light", "dark"] | None = None
    motion_preference: Literal["system", "reduce"] | None = None
    default_module_id: uuid.UUID | None = None
    daily_review_target: int | None = Field(default=None, ge=1, le=100)
    reminder_daily_review: bool | None = None
    reminder_processing_attention: bool | None = None
    reminder_paper_review: bool | None = None
    reminder_health_attention: bool | None = None

    @model_validator(mode="after")
    def reject_explicit_nulls(self):
        nullable = {"default_module_id"}
        invalid = [
            name
            for name in self.model_fields_set
            if name not in nullable and getattr(self, name) is None
        ]
        if invalid:
            raise ValueError(f"Fields cannot be null: {', '.join(sorted(invalid))}")
        return self


class NotificationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    kind: str
    title: str
    body: str
    href: str
    created_at: datetime
    read_at: datetime | None


class NotificationPageResponse(BaseModel):
    items: list[NotificationResponse]
    unread_count: int


class NotificationCountResponse(BaseModel):
    unread_count: int


class ActivityEntryResponse(BaseModel):
    id: uuid.UUID
    event_type: Literal[
        "wiki_revision",
        "source_change",
        "flashcard_evidence",
        "paper_evidence",
        "summary",
        "outline",
        "study_guide",
        "processing_failure",
    ]
    category: Literal["content", "evidence", "study_guides"]
    title: str
    summary: str
    href: str
    resource_id: uuid.UUID | None
    created_at: datetime
    revision_number: int | None = None
