import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import DateTime, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, gen_uuid


class SourceChunk(Base):
    __tablename__ = "source_chunks"
    __table_args__ = (
        Index("ix_source_chunks_source_id", "source_id"),
        Index("uq_source_chunks_source_index", "source_id", "chunk_index", unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    source_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("sources.id", ondelete="CASCADE"))
    chunk_index: Mapped[int] = mapped_column(Integer)
    citation_ref: Mapped[str] = mapped_column(String(1000))
    location_label: Mapped[str] = mapped_column(String(255), default="")
    content: Mapped[str] = mapped_column(Text)
    token_count: Mapped[int] = mapped_column(Integer)
    embedding: Mapped[list[float] | None] = mapped_column(Vector(1536))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")

    source: Mapped["Source"] = relationship(back_populates="chunks")  # noqa: F821
