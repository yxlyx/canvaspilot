import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, field_validator

from app.models.ingestion_job import IngestionJobStatus


class IngestionJobCreate(BaseModel):
    source_ids: list[uuid.UUID]

    @field_validator("source_ids")
    @classmethod
    def require_sources(cls, value: list[uuid.UUID]) -> list[uuid.UUID]:
        deduped = list(dict.fromkeys(value))
        if not deduped:
            raise ValueError("At least one source is required")
        return deduped


class IngestionJobResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    status: IngestionJobStatus
    source_ids: list[uuid.UUID]
    batch_key: str
    source_count: int
    imported_source_count: int
    chunk_count: int
    error_message: str | None
    started_at: datetime | None
    completed_at: datetime | None
    created_at: datetime
    updated_at: datetime
