"""add account settings and in-app notifications

Revision ID: f1a2b3c4d5e6
Revises: e1f6a7b8c9d0
Create Date: 2026-07-22 23:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f1a2b3c4d5e6"
down_revision: str | Sequence[str] | None = "e1f6a7b8c9d0"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("auth_version", sa.Integer(), nullable=False, server_default="0"),
    )
    op.create_table(
        "user_preferences",
        sa.Column(
            "user_id",
            sa.UUID(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("theme", sa.String(16), nullable=False, server_default="system"),
        sa.Column("motion_preference", sa.String(16), nullable=False, server_default="system"),
        sa.Column(
            "default_module_id",
            sa.UUID(),
            sa.ForeignKey("modules.id", ondelete="SET NULL"),
        ),
        sa.Column("daily_review_target", sa.Integer(), nullable=False, server_default="10"),
        sa.Column("reminder_daily_review", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column(
            "reminder_processing_attention",
            sa.Boolean(),
            nullable=False,
            server_default=sa.true(),
        ),
        sa.Column("reminder_paper_review", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column(
            "reminder_health_attention", sa.Boolean(), nullable=False, server_default=sa.true()
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.CheckConstraint(
            "theme IN ('system', 'light', 'dark')", name="ck_user_preferences_theme"
        ),
        sa.CheckConstraint(
            "motion_preference IN ('system', 'reduce')", name="ck_user_preferences_motion"
        ),
        sa.CheckConstraint(
            "daily_review_target BETWEEN 1 AND 100",
            name="ck_user_preferences_review_target",
        ),
    )
    op.create_table(
        "in_app_notifications",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("kind", sa.String(50), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("body", sa.Text(), nullable=False, server_default=""),
        sa.Column("href", sa.String(1000), nullable=False, server_default="/notifications"),
        sa.Column("dedupe_key", sa.String(255), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.Column("read_at", sa.DateTime(timezone=True)),
        sa.Column("expires_at", sa.DateTime(timezone=True)),
    )
    op.create_index(
        "uq_in_app_notifications_user_dedupe",
        "in_app_notifications",
        ["user_id", "dedupe_key"],
        unique=True,
    )
    op.create_index(
        "ix_in_app_notifications_user_created",
        "in_app_notifications",
        ["user_id", "created_at", "id"],
    )


def downgrade() -> None:
    op.drop_index("ix_in_app_notifications_user_created", table_name="in_app_notifications")
    op.drop_index("uq_in_app_notifications_user_dedupe", table_name="in_app_notifications")
    op.drop_table("in_app_notifications")
    op.drop_table("user_preferences")
    op.drop_column("users", "auth_version")
