import uuid
from datetime import datetime

from sqlalchemy import DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid


class User(TimestampMixin, Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    canvas_user_id: Mapped[int] = mapped_column(Integer, unique=True, index=True)
    name: Mapped[str] = mapped_column(String(255))
    email: Mapped[str] = mapped_column(String(255))
    encrypted_access_token: Mapped[str] = mapped_column(String(1024))
    encrypted_refresh_token: Mapped[str] = mapped_column(String(1024))
    token_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    modules: Mapped[list["Module"]] = relationship(back_populates="user", lazy="selectin")  # noqa: F821
    tasks: Mapped[list["Task"]] = relationship(back_populates="user", lazy="selectin")  # noqa: F821
