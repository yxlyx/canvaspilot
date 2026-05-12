import enum
import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, Enum, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid


class TaskType(enum.StrEnum):
    ASSIGNMENT = "assignment"
    QUIZ = "quiz"
    TUTORIAL = "tutorial"
    EXAM = "exam"
    CUSTOM = "custom"


class Task(TimestampMixin, Base):
    __tablename__ = "tasks"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    module_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("modules.id", ondelete="CASCADE"))
    title: Mapped[str] = mapped_column(String(1000))
    task_type: Mapped[TaskType] = mapped_column(Enum(TaskType))
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    source_type: Mapped[str] = mapped_column(String(50), default="")
    source_id: Mapped[str] = mapped_column(String(255), default="")
    source_url: Mapped[str] = mapped_column(String(2048), default="")

    user: Mapped["User"] = relationship(back_populates="tasks")  # noqa: F821
    module: Mapped["Module"] = relationship()  # noqa: F821
