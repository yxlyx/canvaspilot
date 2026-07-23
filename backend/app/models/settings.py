import uuid
from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Index, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, TimestampMixin, gen_uuid


class UserPreference(TimestampMixin, Base):
    __tablename__ = "user_preferences"
    __table_args__ = (
        CheckConstraint("theme IN ('system', 'light', 'dark')", name="ck_user_preferences_theme"),
        CheckConstraint(
            "motion_preference IN ('system', 'reduce')",
            name="ck_user_preferences_motion",
        ),
        CheckConstraint(
            "daily_review_target BETWEEN 1 AND 100",
            name="ck_user_preferences_review_target",
        ),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    theme: Mapped[str] = mapped_column(String(16), default="system", server_default="system")
    motion_preference: Mapped[str] = mapped_column(
        String(16), default="system", server_default="system"
    )
    default_module_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("modules.id", ondelete="SET NULL")
    )
    daily_review_target: Mapped[int] = mapped_column(Integer, default=10, server_default="10")
    reminder_daily_review: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default="true"
    )
    reminder_processing_attention: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default="true"
    )
    reminder_paper_review: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default="true"
    )
    reminder_health_attention: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default="true"
    )


class InAppNotification(Base):
    __tablename__ = "in_app_notifications"
    __table_args__ = (
        Index(
            "uq_in_app_notifications_user_dedupe",
            "user_id",
            "dedupe_key",
            unique=True,
        ),
        Index(
            "ix_in_app_notifications_user_created",
            "user_id",
            "created_at",
            "id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(50))
    title: Mapped[str] = mapped_column(String(200))
    body: Mapped[str] = mapped_column(Text, default="", server_default="")
    href: Mapped[str] = mapped_column(String(1000), default="/notifications")
    dedupe_key: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
