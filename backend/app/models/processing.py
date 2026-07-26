import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid

STAGE_NAMES = ("parse_index", "topic_proposals", "coverage", "wiki", "flashcards")
TERMINAL_RUN_STATES = ("ready", "failed", "cancelled")


class SourceVersion(Base):
    __tablename__ = "source_versions"
    __table_args__ = (
        Index("uq_source_versions_source_number", "source_id", "version_number", unique=True),
        Index("uq_source_versions_source_fingerprint", "source_id", "fingerprint", unique=True),
        CheckConstraint("version_number > 0", name="ck_source_versions_number"),
        CheckConstraint("length(fingerprint) = 64", name="ck_source_versions_fingerprint"),
        CheckConstraint(
            "status IN ('pending', 'processing', 'ready', 'failed', 'cancelled')",
            name="ck_source_versions_status",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    source_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sources.id", ondelete="CASCADE"))
    version_number: Mapped[int] = mapped_column(Integer)
    fingerprint: Mapped[str] = mapped_column(String(64))
    filename: Mapped[str | None] = mapped_column(String(255))
    payload: Mapped[dict] = mapped_column(JSONB, default=dict)
    status: Mapped[str] = mapped_column(String(20), default="pending")
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    ready_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ProcessingPolicy(TimestampMixin, Base):
    __tablename__ = "processing_policies"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    process_sources: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    map_topics: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    compile_wiki: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")
    flashcard_mode: Mapped[str] = mapped_column(
        String(16), default="suggest", server_default="suggest"
    )
    require_deck_review: Mapped[bool] = mapped_column(Boolean, default=True, server_default="true")

    __table_args__ = (
        CheckConstraint(
            "flashcard_mode IN ('off', 'suggest', 'draft')",
            name="ck_processing_policies_flashcard_mode",
        ),
        CheckConstraint("require_deck_review = true", name="ck_processing_policies_review_gate"),
    )


class ProcessingRun(TimestampMixin, Base):
    __tablename__ = "processing_runs"
    __table_args__ = (
        Index("uq_processing_runs_user_key", "user_id", "idempotency_key", unique=True),
        Index("ix_processing_runs_claim", "status", "next_attempt_at", "created_at"),
        Index("ix_processing_runs_source", "source_id", "created_at"),
        CheckConstraint(
            "status IN ('queued', 'running', 'paused', 'ready', 'failed', 'cancelled')",
            name="ck_processing_runs_status",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sources.id", ondelete="CASCADE"))
    source_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("source_versions.id", ondelete="CASCADE")
    )
    idempotency_key: Mapped[str] = mapped_column(String(128))
    causation_id: Mapped[uuid.UUID | None] = mapped_column()
    status: Mapped[str] = mapped_column(String(20), default="queued")
    current_stage: Mapped[str] = mapped_column(String(32), default="parse_index")
    policy_snapshot: Mapped[dict] = mapped_column(JSONB, default=dict)
    attempt_count: Mapped[int] = mapped_column(Integer, default=0)
    next_attempt_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default="now()"
    )
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    pause_reason: Mapped[str | None] = mapped_column(String(64))
    error_code: Mapped[str | None] = mapped_column(String(64))
    error: Mapped[str | None] = mapped_column(Text)

    stages: Mapped[list["ProcessingStage"]] = relationship(
        cascade="all, delete-orphan", lazy="selectin", order_by="ProcessingStage.position"
    )
    events: Mapped[list["ProcessingEvent"]] = relationship(
        cascade="all, delete-orphan", lazy="selectin", order_by="ProcessingEvent.created_at"
    )


class ProcessingEnqueueRequest(Base):
    __tablename__ = "processing_enqueue_requests"
    __table_args__ = (
        Index("uq_processing_enqueue_requests_user_key", "user_id", "idempotency_key", unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    run_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("processing_runs.id", ondelete="CASCADE"))
    source_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("source_versions.id", ondelete="CASCADE")
    )
    idempotency_key: Mapped[str] = mapped_column(String(128))
    request_hash: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")


class ProcessingStage(Base):
    __tablename__ = "processing_stages"
    __table_args__ = (
        UniqueConstraint("run_id", "name", name="uq_processing_stages_run_name"),
        Index("ix_processing_stages_claim", "status", "available_at", "position"),
        CheckConstraint(
            "attempt_count >= 0 AND max_attempts > 0", name="ck_processing_stages_attempts"
        ),
        CheckConstraint(
            "status IN ('blocked', 'queued', 'running', 'paused', 'succeeded', "
            "'skipped', 'failed', 'cancelled')",
            name="ck_processing_stages_status",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    run_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("processing_runs.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(32))
    position: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20), default="blocked")
    attempt_count: Mapped[int] = mapped_column(Integer, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, default=3)
    available_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    lease_owner: Mapped[str | None] = mapped_column(String(128))
    lease_token: Mapped[int] = mapped_column(Integer, default=0)
    lease_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    input_fingerprint: Mapped[str | None] = mapped_column(String(64))
    output_fingerprint: Mapped[str | None] = mapped_column(String(64))
    outcome: Mapped[dict] = mapped_column(JSONB, default=dict)
    error_code: Mapped[str | None] = mapped_column(String(64))
    error: Mapped[str | None] = mapped_column(Text)


class ProcessingCoverageSnapshot(Base):
    __tablename__ = "processing_coverage_snapshots"
    __table_args__ = (
        Index(
            "uq_processing_coverage_source_version",
            "enrollment_id",
            "source_version_id",
            unique=True,
        ),
        CheckConstraint("length(fingerprint) = 64", name="ck_processing_coverage_fingerprint"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    run_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("processing_runs.id", ondelete="CASCADE"))
    enrollment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("module_enrollments.id", ondelete="CASCADE")
    )
    source_version_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("source_versions.id", ondelete="CASCADE")
    )
    fingerprint: Mapped[str] = mapped_column(String(64))
    snapshot: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")


class ProcessingEvent(Base):
    __tablename__ = "processing_events"
    __table_args__ = (
        Index("uq_processing_events_run_key", "run_id", "dedupe_key", unique=True),
        Index("ix_processing_events_user_created", "user_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    run_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("processing_runs.id", ondelete="CASCADE"))
    stage_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("processing_stages.id", ondelete="CASCADE")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    event_type: Mapped[str] = mapped_column(String(64))
    dedupe_key: Mapped[str] = mapped_column(String(128))
    payload: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
