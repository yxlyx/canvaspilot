import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid


class IdempotencyRecord(Base):
    __tablename__ = "idempotency_records"
    __table_args__ = (
        Index("uq_idempotency_records_user_key", "user_id", "idempotency_key", unique=True),
        Index("ix_idempotency_records_created_at", "created_at"),
        Index("ix_idempotency_records_expires_at", "expires_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    idempotency_key: Mapped[str] = mapped_column(String(128))
    operation: Mapped[str] = mapped_column(String(200))
    request_hash: Mapped[str] = mapped_column(String(64))
    response_status: Mapped[int | None] = mapped_column(Integer)
    response_body: Mapped[dict | list | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now() + interval '24 hours'")
    )


class StudyOutput(TimestampMixin, Base):
    __tablename__ = "study_outputs"
    __table_args__ = (Index("ix_study_outputs_user_created", "user_id", "created_at", "id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    output_type: Mapped[str] = mapped_column(String(50))
    title: Mapped[str] = mapped_column(String(300))
    status: Mapped[str] = mapped_column(String(50))
    content: Mapped[str] = mapped_column(Text, default="")
    source_ids: Mapped[list[uuid.UUID]] = mapped_column(ARRAY(UUID(as_uuid=True)), default=list)
    wiki_page_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("wiki_pages.id", ondelete="SET NULL")
    )
    message: Mapped[str] = mapped_column(Text, default="")
    citations: Mapped[list["StudyOutputCitation"]] = relationship(
        cascade="all, delete-orphan", lazy="selectin"
    )


class StudyOutputCitation(Base):
    __tablename__ = "study_output_citations"
    __table_args__ = (Index("ix_study_output_citations_output", "output_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    output_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("study_outputs.id", ondelete="CASCADE"))
    source_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sources.id", ondelete="CASCADE"))
    source_chunk_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("source_chunks.id", ondelete="SET NULL")
    )
    citation_key: Mapped[str] = mapped_column(String(64))
    citation_ref: Mapped[str] = mapped_column(String(1000))
    source_title: Mapped[str] = mapped_column(String(1000))
    snippet: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")


class WikiRevision(Base):
    __tablename__ = "wiki_revisions"
    __table_args__ = (
        Index("ix_wiki_revisions_user_created", "user_id", "created_at"),
        Index("uq_wiki_revisions_page_number", "page_id", "revision_number", unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    page_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    revision_number: Mapped[int] = mapped_column(Integer)
    title: Mapped[str] = mapped_column(String(1000))
    markdown: Mapped[str] = mapped_column(Text)
    source_ids: Mapped[list[uuid.UUID]] = mapped_column(ARRAY(UUID(as_uuid=True)), default=list)
    citation_count: Mapped[int] = mapped_column(Integer, default=0)
    change_summary: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")


class SourceChange(Base):
    __tablename__ = "source_changes"
    __table_args__ = (Index("ix_source_changes_user_created", "user_id", "created_at"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True))
    source_title: Mapped[str] = mapped_column(String(1000), default="")
    change_type: Mapped[str] = mapped_column(String(50))
    before_snapshot: Mapped[dict] = mapped_column(JSONB, default=dict)
    after_snapshot: Mapped[dict] = mapped_column(JSONB, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")


class HealthFinding(Base):
    __tablename__ = "health_findings"
    __table_args__ = (Index("ix_health_findings_user_created", "user_id", "created_at"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    code: Mapped[str] = mapped_column(String(50))
    severity: Mapped[str] = mapped_column(String(20))
    state: Mapped[str] = mapped_column(String(20))
    resource_type: Mapped[str] = mapped_column(String(50))
    resource_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    topic: Mapped[str | None] = mapped_column(String(100))
    message: Mapped[str] = mapped_column(Text)
    recommendation: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")


class MarkedPaper(TimestampMixin, Base):
    __tablename__ = "marked_papers"
    __table_args__ = (Index("ix_marked_papers_user_created", "user_id", "created_at", "id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    filename: Mapped[str] = mapped_column(String(255))
    content_type: Mapped[str] = mapped_column(String(100))
    raw_content: Mapped[bytes] = mapped_column(LargeBinary)
    extraction_status: Mapped[str] = mapped_column(String(50), default="pending_review")
    extraction_message: Mapped[str] = mapped_column(Text, default="")
    questions: Mapped[list["MarkedPaperQuestion"]] = relationship(
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="MarkedPaperQuestion.question_number",
    )


class MarkedPaperQuestion(Base):
    __tablename__ = "marked_paper_questions"
    __table_args__ = (
        CheckConstraint(
            "(awarded_marks IS NULL OR awarded_marks >= 0) AND "
            "(available_marks IS NULL OR available_marks > 0) AND "
            "(awarded_marks IS NULL OR available_marks IS NULL "
            "OR awarded_marks <= available_marks)",
            name="ck_marked_question_marks",
        ),
        Index("ix_marked_questions_paper", "paper_id"),
        Index("uq_marked_questions_paper_number", "paper_id", "question_number", unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    paper_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("marked_papers.id", ondelete="CASCADE"))
    question_number: Mapped[int] = mapped_column(Integer)
    question_text: Mapped[str] = mapped_column(Text)
    awarded_marks: Mapped[float | None] = mapped_column(Float)
    available_marks: Mapped[float | None] = mapped_column(Float)
    feedback: Mapped[str] = mapped_column(Text, default="")
    topic_tag: Mapped[str] = mapped_column(String(100), default="general")
    confidence: Mapped[float] = mapped_column(Float, default=0.5)
    reviewed: Mapped[bool] = mapped_column(Boolean, default=False)
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ProviderSetting(TimestampMixin, Base):
    __tablename__ = "provider_settings"
    __table_args__ = (
        Index("uq_provider_settings_user_provider", "user_id", "provider", unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    provider: Mapped[str] = mapped_column(String(50))
    model: Mapped[str] = mapped_column(String(100))
    endpoint: Mapped[str] = mapped_column(String(500))
    auth_method: Mapped[str] = mapped_column(String(30), default="api_key")
    encrypted_api_key: Mapped[bytes | None] = mapped_column(LargeBinary)
    encrypted_access_token: Mapped[bytes | None] = mapped_column(LargeBinary)
    encrypted_refresh_token: Mapped[bytes | None] = mapped_column(LargeBinary)
    encryption_key_id: Mapped[str] = mapped_column(String(100))
    access_token_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    provider_account_id: Mapped[str | None] = mapped_column(String(255))
    provider_subject_id: Mapped[str | None] = mapped_column(String(255))
    provider_account_label: Mapped[str | None] = mapped_column(String(320))
    granted_scopes: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(50), default="configured")
    active_for_generation: Mapped[bool] = mapped_column(Boolean, default=False)
    last_error: Mapped[str | None] = mapped_column(Text)
    last_error_code: Mapped[str | None] = mapped_column(String(100))
    last_tested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_refreshed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ProviderAuthorizationSession(Base):
    __tablename__ = "provider_authorization_sessions"
    __table_args__ = (
        Index("ix_provider_auth_sessions_user_created", "user_id", "created_at"),
        Index("ix_provider_auth_sessions_expires", "expires_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    provider: Mapped[str] = mapped_column(String(50))
    auth_method: Mapped[str] = mapped_column(String(30))
    state_hash: Mapped[str | None] = mapped_column(String(64), unique=True)
    encrypted_pkce_verifier: Mapped[bytes | None] = mapped_column(LargeBinary)
    encrypted_device_code: Mapped[bytes | None] = mapped_column(LargeBinary)
    encryption_key_id: Mapped[str] = mapped_column(String(100))
    nonce_hash: Mapped[str | None] = mapped_column(String(64))
    browser_binding_hash: Mapped[str | None] = mapped_column(String(64))
    verification_uri: Mapped[str | None] = mapped_column(String(500))
    verification_uri_complete: Mapped[str | None] = mapped_column(String(1000))
    user_code: Mapped[str | None] = mapped_column(String(100))
    poll_interval_seconds: Mapped[int | None] = mapped_column(Integer)
    next_poll_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    return_path: Mapped[str] = mapped_column(String(500))
    status: Mapped[str] = mapped_column(String(30), default="pending")
    error_code: Mapped[str | None] = mapped_column(String(100))
    error_message: Mapped[str | None] = mapped_column(Text)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
