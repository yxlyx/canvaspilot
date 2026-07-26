import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    and_,
    or_,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, gen_uuid


def is_active_source_chunk(chunk, source) -> bool:
    return chunk.source_version_id == source.current_version_id


def active_source_chunk_predicate(chunk, source):
    chunk_columns = getattr(chunk, "c", chunk)
    source_columns = getattr(source, "c", source)
    return or_(
        chunk_columns.source_version_id == source_columns.current_version_id,
        and_(
            source_columns.current_version_id.is_(None),
            chunk_columns.source_version_id.is_(None),
        ),
    )


def active_source_chunk_sql(chunk_alias: str, source_alias: str) -> str:
    return (
        f"({chunk_alias}.source_version_id = {source_alias}.current_version_id OR "
        f"({source_alias}.current_version_id IS NULL AND "
        f"{chunk_alias}.source_version_id IS NULL))"
    )


class SourceChunk(Base):
    __tablename__ = "source_chunks"
    __table_args__ = (
        Index("ix_source_chunks_source_id", "source_id"),
        UniqueConstraint("source_version_id", "chunk_index", name="uq_source_chunks_version_index"),
        Index("ix_source_chunks_fingerprint", "fingerprint"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    source_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sources.id", ondelete="CASCADE"))
    source_version_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("source_versions.id", ondelete="CASCADE")
    )
    fingerprint: Mapped[str | None] = mapped_column(String(64))
    chunk_index: Mapped[int] = mapped_column(Integer)
    citation_ref: Mapped[str] = mapped_column(String(1000))
    location_label: Mapped[str] = mapped_column(String(255), default="")
    content: Mapped[str] = mapped_column(Text)
    token_count: Mapped[int] = mapped_column(Integer)
    embedding: Mapped[list[float] | None] = mapped_column(Vector(1536))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")

    source: Mapped["Source"] = relationship(back_populates="chunks")  # noqa: F821
