import enum
import uuid
from datetime import datetime

from sqlalchemy import DateTime, Enum, ForeignKey, Index, Integer, String, Text, text
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid
from app.models.source import enum_values


class IngestionJobStatus(enum.StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


ACTIVE_INGESTION_JOB_STATUSES = (
    IngestionJobStatus.QUEUED,
    IngestionJobStatus.RUNNING,
)


class IngestionJob(TimestampMixin, Base):
    __tablename__ = "ingestion_jobs"
    __table_args__ = (
        Index("ix_ingestion_jobs_user_status", "user_id", "status"),
        Index("ix_ingestion_jobs_user_created_at", "user_id", "created_at"),
        Index("ix_ingestion_jobs_user_batch_key", "user_id", "batch_key"),
        Index(
            "uq_ingestion_jobs_active_batch",
            "user_id",
            "batch_key",
            unique=True,
            postgresql_where=text("status IN ('queued', 'running')"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    status: Mapped[IngestionJobStatus] = mapped_column(
        Enum(
            IngestionJobStatus,
            name="ingestionjobstatus",
            values_callable=enum_values,
        ),
        default=IngestionJobStatus.QUEUED,
    )
    source_ids: Mapped[list[uuid.UUID]] = mapped_column(ARRAY(UUID(as_uuid=True)))
    batch_key: Mapped[str] = mapped_column(String(2048))
    source_count: Mapped[int] = mapped_column(Integer, default=0)
    imported_source_count: Mapped[int] = mapped_column(Integer, default=0)
    chunk_count: Mapped[int] = mapped_column(Integer, default=0)
    error_message: Mapped[str | None] = mapped_column(Text)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    user: Mapped["User"] = relationship(back_populates="ingestion_jobs")  # noqa: F821
