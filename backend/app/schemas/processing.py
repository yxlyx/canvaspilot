import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class ProcessingPolicyResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    process_sources: bool
    map_topics: bool
    compile_wiki: bool
    flashcard_mode: Literal["off", "suggest", "draft"]
    require_deck_review: bool
    updated_at: datetime


class ProcessingPolicyUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    process_sources: bool | None = None
    map_topics: bool | None = None
    compile_wiki: bool | None = None
    flashcard_mode: Literal["off", "suggest", "draft"] | None = None


class ProcessingEventResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    stage_id: uuid.UUID | None
    event_type: str
    payload: dict
    created_at: datetime


class ProcessingStageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    position: int
    status: str
    attempt_count: int
    max_attempts: int
    available_at: datetime
    lease_token: int
    lease_expires_at: datetime | None
    started_at: datetime | None
    completed_at: datetime | None
    outcome: dict
    error_code: str | None
    error: str | None


class ProcessingRunResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    source_id: uuid.UUID
    source_version_id: uuid.UUID
    causation_id: uuid.UUID | None
    status: str
    current_stage: str
    policy_snapshot: dict
    attempt_count: int
    next_attempt_at: datetime
    started_at: datetime | None
    completed_at: datetime | None
    cancelled_at: datetime | None
    pause_reason: str | None
    error_code: str | None
    error: str | None
    created_at: datetime
    updated_at: datetime
    stages: list[ProcessingStageResponse]
    events: list[ProcessingEventResponse]


class RetryRunRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    from_stage: (
        Literal["parse_index", "topic_proposals", "coverage", "wiki", "flashcards"] | None
    ) = None


class ManualTriggerRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    source_id: uuid.UUID


class WorkerRunRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    limit: int = Field(default=1, ge=1, le=100)
