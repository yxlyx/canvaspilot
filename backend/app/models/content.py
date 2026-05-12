import enum
import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import DateTime, Enum, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, gen_uuid


class SourceType(enum.StrEnum):
    ANNOUNCEMENT = "announcement"
    ASSIGNMENT = "assignment"
    FILE = "file"
    PAGE = "page"


class ContentChunk(Base):
    __tablename__ = "content_chunks"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    module_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("modules.id", ondelete="CASCADE"))
    source_type: Mapped[SourceType] = mapped_column(Enum(SourceType))
    source_id: Mapped[str] = mapped_column(String(255))
    source_title: Mapped[str] = mapped_column(String(1000))
    source_url: Mapped[str] = mapped_column(String(2048), default="")
    content: Mapped[str] = mapped_column(Text)
    token_count: Mapped[int] = mapped_column(Integer)
    embedding: Mapped[list[float] | None] = mapped_column(Vector(1536))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")

    module: Mapped["Module"] = relationship(back_populates="chunks")  # noqa: F821
