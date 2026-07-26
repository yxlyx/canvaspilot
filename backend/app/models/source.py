import enum
import uuid
from datetime import datetime

from sqlalchemy import DateTime, Enum, ForeignKey, Index, String, Text, text
from sqlalchemy.dialects.postgresql import ARRAY
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid


class SourceKind(enum.StrEnum):
    MARKDOWN = "markdown"
    PLAIN_TEXT = "plain_text"
    PDF = "pdf"
    IMAGE = "image"
    LINK = "link"
    REPOSITORY = "repository"


class SourceStatus(enum.StrEnum):
    PENDING = "pending"
    INDEXING = "indexing"
    READY = "ready"
    FAILED = "failed"
    ARCHIVED = "archived"


def enum_values(enum_class: type[enum.StrEnum]) -> list[str]:
    return [member.value for member in enum_class]


class Source(TimestampMixin, Base):
    __tablename__ = "sources"
    __table_args__ = (
        Index("ix_sources_user_updated_at", "user_id", "updated_at"),
        Index("ix_sources_user_source_type", "user_id", "source_type"),
        Index("ix_sources_user_status", "user_id", "status"),
        Index("ix_sources_user_title", "user_id", "title"),
        Index("ix_sources_topic_tags", "topic_tags", postgresql_using="gin"),
        Index(
            "uq_sources_user_origin_external",
            "user_id",
            "origin",
            "external_id",
            unique=True,
            postgresql_where=text("external_id IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    enrollment_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("module_enrollments.id", ondelete="SET NULL")
    )
    source_type: Mapped[SourceKind] = mapped_column(
        Enum(SourceKind, name="librarysourcetype", values_callable=enum_values)
    )
    origin: Mapped[str] = mapped_column(String(255))
    external_id: Mapped[str | None] = mapped_column(String(512))
    title: Mapped[str] = mapped_column(String(1000))
    source_url: Mapped[str] = mapped_column(String(2048), default="")
    citation_label: Mapped[str] = mapped_column(String(1000))
    topic_tags: Mapped[list[str]] = mapped_column(ARRAY(String(100)), default=list)
    metadata_overrides: Mapped[list[str]] = mapped_column(
        ARRAY(String(32)), default=list, server_default=text("'{}'::varchar[]")
    )
    status: Mapped[SourceStatus] = mapped_column(
        Enum(SourceStatus, name="sourcestatus", values_callable=enum_values),
        default=SourceStatus.PENDING,
    )
    course_context: Mapped[str | None] = mapped_column(String(255))
    project_context: Mapped[str | None] = mapped_column(String(255))
    last_imported_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    import_error: Mapped[str | None] = mapped_column(Text)
    current_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("source_versions.id", ondelete="SET NULL")
    )

    user: Mapped["User"] = relationship(back_populates="sources")  # noqa: F821
    chunks: Mapped[list["SourceChunk"]] = relationship(  # noqa: F821
        back_populates="source",
        cascade="all, delete-orphan",
        lazy="selectin",
    )
