import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Index, Integer, String, Text, text
from sqlalchemy.dialects.postgresql import ARRAY, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid


class WikiPage(TimestampMixin, Base):
    __tablename__ = "wiki_pages"
    __table_args__ = (
        Index("ix_wiki_pages_user_slug", "user_id", "slug", unique=True),
        Index("ix_wiki_pages_user_updated_at", "user_id", "updated_at"),
        Index("ix_wiki_pages_source_ids", "source_ids", postgresql_using="gin"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    slug: Mapped[str] = mapped_column(String(255))
    title: Mapped[str] = mapped_column(String(1000))
    page_type: Mapped[str] = mapped_column(String(50), default="source")
    is_current: Mapped[bool] = mapped_column(Boolean, default=True)
    markdown: Mapped[str] = mapped_column(Text)
    summary: Mapped[str] = mapped_column(Text, default="")
    source_ids: Mapped[list[uuid.UUID]] = mapped_column(
        ARRAY(UUID(as_uuid=True)),
        default=list,
        server_default=text("'{}'::uuid[]"),
    )
    citation_count: Mapped[int] = mapped_column(Integer, default=0)
    input_fingerprint: Mapped[str | None] = mapped_column(String(64))
    backlinks: Mapped[list[str]] = mapped_column(
        ARRAY(String(255)),
        default=list,
        server_default=text("'{}'::character varying[]"),
    )

    citations: Mapped[list["WikiCitation"]] = relationship(  # noqa: F821
        back_populates="page",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class WikiCitation(Base):
    __tablename__ = "wiki_citations"
    __table_args__ = (
        Index("ix_wiki_citations_page_id", "page_id"),
        Index("ix_wiki_citations_source_id", "source_id"),
        Index("ix_wiki_citations_source_chunk_id", "source_chunk_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    page_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("wiki_pages.id", ondelete="CASCADE"))
    source_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sources.id", ondelete="CASCADE"))
    source_chunk_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("source_chunks.id", ondelete="SET NULL")
    )
    citation_key: Mapped[str] = mapped_column(String(64))
    citation_ref: Mapped[str] = mapped_column(String(1000))
    source_title: Mapped[str] = mapped_column(String(1000))
    location_label: Mapped[str] = mapped_column(String(255), default="")
    chunk_index: Mapped[int | None] = mapped_column(Integer)
    snippet: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")

    page: Mapped[WikiPage] = relationship(back_populates="citations")
