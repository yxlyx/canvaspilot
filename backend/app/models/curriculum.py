import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid


class CatalogModule(TimestampMixin, Base):
    __tablename__ = "catalog_modules"
    __table_args__ = (
        Index(
            "uq_catalog_modules_institution_code",
            "institution",
            "canonical_code",
            unique=True,
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    institution: Mapped[str] = mapped_column(String(100))
    canonical_code: Mapped[str] = mapped_column(String(32))
    code: Mapped[str] = mapped_column(String(32))
    title: Mapped[str] = mapped_column(String(500))
    description: Mapped[str] = mapped_column(Text, default="")
    metadata_json: Mapped[dict] = mapped_column(JSONB, default=dict)


class ProviderModuleSnapshot(Base):
    __tablename__ = "provider_module_snapshots"
    __table_args__ = (
        CheckConstraint(
            "length(payload_sha256) = 64", name="ck_provider_module_snapshots_payload_sha256"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    provider: Mapped[str] = mapped_column(String(32))
    academic_year: Mapped[str] = mapped_column(String(9))
    module_code: Mapped[str] = mapped_column(String(32))
    provider_version: Mapped[str] = mapped_column(String(32))
    source_url: Mapped[str] = mapped_column(String(1000))
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    payload_sha256: Mapped[str] = mapped_column(String(64))
    payload: Mapped[dict] = mapped_column(JSONB)


class SemesterOffering(TimestampMixin, Base):
    __tablename__ = "semester_offerings"
    __table_args__ = (
        Index(
            "uq_semester_offerings_module_year_semester",
            "catalog_module_id",
            "academic_year",
            "semester",
            unique=True,
        ),
        CheckConstraint(
            "academic_year ~ '^[0-9]{4}-[0-9]{4}$' AND "
            "substring(academic_year from 6 for 4)::integer = "
            "substring(academic_year from 1 for 4)::integer + 1 AND "
            "substring(academic_year from 1 for 4)::integer BETWEEN 2000 AND 2100",
            name="ck_semester_offerings_academic_year",
        ),
        CheckConstraint("semester BETWEEN 1 AND 4", name="ck_semester_offerings_semester"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    catalog_module_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("catalog_modules.id", ondelete="CASCADE")
    )
    provider_snapshot_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("provider_module_snapshots.id", ondelete="RESTRICT")
    )
    academic_year: Mapped[str] = mapped_column(String(9))
    semester: Mapped[int] = mapped_column(Integer)
    available: Mapped[bool] = mapped_column(Boolean, default=True)
    metadata_json: Mapped[dict] = mapped_column(JSONB, default=dict)

    catalog_module: Mapped[CatalogModule] = relationship(lazy="joined")
    provider_snapshot: Mapped[ProviderModuleSnapshot] = relationship(lazy="joined")


class ModuleEnrollment(TimestampMixin, Base):
    __tablename__ = "module_enrollments"
    __table_args__ = (
        Index("uq_module_enrollments_user_offering", "user_id", "offering_id", unique=True),
        Index("ix_module_enrollments_user", "user_id"),
        CheckConstraint(
            "provenance IN ('nusmods', 'manual')", name="ck_module_enrollments_provenance"
        ),
        CheckConstraint(
            "import_method IN ('share_url', 'manual_codes')",
            name="ck_module_enrollments_import_method",
        ),
        CheckConstraint(
            "topic_state IN ('provisional', 'canonical')",
            name="ck_module_enrollments_topic_state",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    offering_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("semester_offerings.id", ondelete="CASCADE")
    )
    provenance: Mapped[str] = mapped_column(String(32))
    import_method: Mapped[str] = mapped_column(String(32))
    topic_state: Mapped[str] = mapped_column(String(16), default="provisional")
    evidence_warning: Mapped[str | None] = mapped_column(Text)
    lesson_config: Mapped[dict] = mapped_column(JSONB, default=dict)
    archived: Mapped[bool] = mapped_column(Boolean, default=False)

    offering: Mapped[SemesterOffering] = relationship(lazy="joined")


class ModuleImportPreview(Base):
    __tablename__ = "module_import_previews"
    __table_args__ = (
        Index("ix_module_import_previews_user_created", "user_id", "created_at"),
        CheckConstraint(
            "academic_year ~ '^[0-9]{4}-[0-9]{4}$' AND "
            "substring(academic_year from 6 for 4)::integer = "
            "substring(academic_year from 1 for 4)::integer + 1 AND "
            "substring(academic_year from 1 for 4)::integer BETWEEN 2000 AND 2100",
            name="ck_module_import_previews_academic_year",
        ),
        CheckConstraint("semester BETWEEN 1 AND 4", name="ck_module_import_previews_semester"),
        CheckConstraint(
            "import_method IN ('share_url', 'manual_codes')",
            name="ck_module_import_previews_import_method",
        ),
        CheckConstraint(
            "(committed_at IS NULL AND commit_request IS NULL AND commit_result IS NULL) OR "
            "(committed_at IS NOT NULL AND commit_request IS NOT NULL "
            "AND commit_result IS NOT NULL)",
            name="ck_module_import_previews_commit_snapshot",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    provider: Mapped[str] = mapped_column(String(32), default="nusmods")
    import_method: Mapped[str] = mapped_column(String(32))
    academic_year: Mapped[str] = mapped_column(String(9))
    semester: Mapped[int] = mapped_column(Integer)
    reconciliation: Mapped[dict] = mapped_column(JSONB, default=dict)
    commit_request: Mapped[dict | None] = mapped_column(JSONB)
    commit_result: Mapped[dict | None] = mapped_column(JSONB)
    committed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=text("now() + interval '30 minutes'")
    )

    items: Mapped[list["ModuleImportItem"]] = relationship(
        cascade="all, delete-orphan", lazy="selectin", order_by="ModuleImportItem.position"
    )


class ModuleImportItem(Base):
    __tablename__ = "module_import_items"
    __table_args__ = (
        Index("uq_module_import_items_preview_code", "preview_id", "code", unique=True),
        Index("uq_module_import_items_preview_position", "preview_id", "position", unique=True),
        CheckConstraint("position >= 0", name="ck_module_import_items_position"),
        CheckConstraint(
            "disposition IN ('import', 'already_enrolled', 'restore', 'unavailable', 'not_found')",
            name="ck_module_import_items_disposition",
        ),
        CheckConstraint(
            "payload_sha256 IS NULL OR length(payload_sha256) = 64",
            name="ck_module_import_items_payload_sha256",
        ),
        CheckConstraint(
            "(detail_snapshot IS NULL AND provider_version IS NULL AND source_url IS NULL "
            "AND fetched_at IS NULL AND payload_sha256 IS NULL) OR "
            "(detail_snapshot IS NOT NULL AND provider_version IS NOT NULL "
            "AND source_url IS NOT NULL AND fetched_at IS NOT NULL "
            "AND payload_sha256 IS NOT NULL)",
            name="ck_module_import_items_snapshot_complete",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    preview_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("module_import_previews.id", ondelete="CASCADE")
    )
    position: Mapped[int] = mapped_column(Integer)
    code: Mapped[str] = mapped_column(String(32))
    title: Mapped[str] = mapped_column(String(500), default="")
    available: Mapped[bool] = mapped_column(Boolean, default=False)
    disposition: Mapped[str] = mapped_column(String(32))
    lesson_config: Mapped[dict] = mapped_column(JSONB, default=dict)
    detail_snapshot: Mapped[dict | None] = mapped_column(JSONB)
    provider_version: Mapped[str | None] = mapped_column(String(32))
    source_url: Mapped[str | None] = mapped_column(String(1000))
    fetched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    payload_sha256: Mapped[str | None] = mapped_column(String(64))


class CurriculumTopic(TimestampMixin, Base):
    __tablename__ = "curriculum_topics"
    __table_args__ = (
        Index("uq_curriculum_topics_enrollment_position", "enrollment_id", "position", unique=True),
        Index("ix_curriculum_topics_enrollment", "enrollment_id"),
        UniqueConstraint("id", "enrollment_id", name="uq_curriculum_topics_id_enrollment"),
        CheckConstraint("position >= 0", name="ck_curriculum_topics_position"),
        CheckConstraint("state IN ('provisional', 'canonical')", name="ck_curriculum_topics_state"),
        CheckConstraint(
            "provenance IN ('catalog_description', 'user_review', 'syllabus')",
            name="ck_curriculum_topics_provenance",
        ),
        CheckConstraint("length(extraction_rule_hash) = 64", name="ck_curriculum_topics_rule_hash"),
        CheckConstraint("length(source_sha256) = 64", name="ck_curriculum_topics_source_hash"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    enrollment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("module_enrollments.id", ondelete="CASCADE")
    )
    position: Mapped[int] = mapped_column(Integer)
    title: Mapped[str] = mapped_column(String(300))
    archived: Mapped[bool] = mapped_column(Boolean, default=False)
    state: Mapped[str] = mapped_column(String(16))
    provenance: Mapped[str] = mapped_column(String(64))
    extraction_rule: Mapped[str] = mapped_column(String(32))
    extraction_rule_hash: Mapped[str] = mapped_column(String(64))
    source_text: Mapped[str] = mapped_column(Text)
    source_sha256: Mapped[str] = mapped_column(String(64))


class TopicSourceAssociation(Base):
    __tablename__ = "topic_source_associations"
    __table_args__ = (
        ForeignKeyConstraint(
            ["topic_id", "enrollment_id"],
            ["curriculum_topics.id", "curriculum_topics.enrollment_id"],
            ondelete="CASCADE",
            name="fk_topic_source_associations_topic_enrollment",
        ),
        Index(
            "uq_topic_source_associations_topic_source",
            "topic_id",
            "source_id",
            unique=True,
        ),
        Index("ix_topic_source_associations_enrollment_status", "enrollment_id", "status"),
        Index("ix_topic_source_associations_source", "source_id"),
        CheckConstraint(
            "status IN ('proposed', 'confirmed', 'rejected')",
            name="ck_topic_source_associations_status",
        ),
        CheckConstraint(
            "method IN ('deterministic', 'manual')",
            name="ck_topic_source_associations_method",
        ),
        CheckConstraint(
            "evidence_strength >= 0 AND evidence_strength <= 1",
            name="ck_topic_source_associations_strength",
        ),
        CheckConstraint("length(rule_hash) = 64", name="ck_topic_source_associations_rule_hash"),
        CheckConstraint(
            "length(source_fingerprint) = 64",
            name="ck_topic_source_associations_source_fingerprint",
        ),
        CheckConstraint(
            "length(topic_fingerprint) = 64",
            name="ck_topic_source_associations_topic_fingerprint",
        ),
        CheckConstraint(
            "(status = 'proposed' AND reviewed_at IS NULL AND reviewer_id IS NULL) OR "
            "(status IN ('confirmed', 'rejected') AND reviewed_at IS NOT NULL "
            "AND reviewer_id IS NOT NULL)",
            name="ck_topic_source_associations_review",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    enrollment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("module_enrollments.id", ondelete="CASCADE")
    )
    topic_id: Mapped[uuid.UUID] = mapped_column()
    source_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sources.id", ondelete="CASCADE"))
    status: Mapped[str] = mapped_column(String(16))
    method: Mapped[str] = mapped_column(String(16))
    evidence_strength: Mapped[float] = mapped_column(Float)
    algorithm: Mapped[str] = mapped_column(String(64))
    rule_hash: Mapped[str] = mapped_column(String(64))
    source_fingerprint: Mapped[str] = mapped_column(String(64))
    topic_fingerprint: Mapped[str] = mapped_column(String(64))
    evidence: Mapped[list] = mapped_column(JSONB, default=list)
    reason_code: Mapped[str] = mapped_column(String(64))
    stale: Mapped[bool] = mapped_column(Boolean, default=False)
    stale_reason: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    reviewer_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE")
    )


class TopicRevision(Base):
    __tablename__ = "topic_revisions"
    __table_args__ = (
        Index("ix_topic_revisions_enrollment_created", "enrollment_id", "created_at"),
        CheckConstraint(
            "status IN ('pending', 'accepted', 'rejected')", name="ck_topic_revisions_status"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    enrollment_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("module_enrollments.id", ondelete="CASCADE")
    )
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sources.id", ondelete="SET NULL")
    )
    status: Mapped[str] = mapped_column(String(16))
    base_topics: Mapped[list] = mapped_column(JSONB)
    proposed_topics: Mapped[list] = mapped_column(JSONB)
    mapping: Mapped[dict] = mapped_column(JSONB, default=dict)
    algorithm: Mapped[str] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
