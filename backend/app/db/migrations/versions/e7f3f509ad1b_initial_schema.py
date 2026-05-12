"""initial schema

Revision ID: e7f3f509ad1b
Revises:
Create Date: 2026-05-11 16:17:58.635465

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector

revision: str = "e7f3f509ad1b"
down_revision: str | Sequence[str] | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        "users",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("canvas_user_id", sa.Integer(), unique=True, nullable=False),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("email", sa.String(255), nullable=False),
        sa.Column("encrypted_access_token", sa.String(1024), nullable=False),
        sa.Column("encrypted_refresh_token", sa.String(1024), nullable=False),
        sa.Column("token_expires_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_users_canvas_user_id", "users", ["canvas_user_id"])

    op.create_table(
        "modules",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("canvas_course_id", sa.Integer(), nullable=False),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("name", sa.String(500), nullable=False),
        sa.Column("code", sa.String(50), nullable=False),
        sa.Column("term", sa.String(50), server_default=""),
        sa.Column("last_synced_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_modules_canvas_course_id", "modules", ["canvas_course_id"])

    op.create_table(
        "announcements",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("canvas_id", sa.Integer(), nullable=False),
        sa.Column(
            "module_id", sa.UUID(), sa.ForeignKey("modules.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("title", sa.String(1000), nullable=False),
        sa.Column("content_html", sa.Text(), server_default=""),
        sa.Column("content_text", sa.Text(), server_default=""),
        sa.Column("posted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("summary", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_announcements_canvas_id", "announcements", ["canvas_id"])

    op.create_table(
        "assignments",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("canvas_id", sa.Integer(), nullable=False),
        sa.Column(
            "module_id", sa.UUID(), sa.ForeignKey("modules.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("title", sa.String(1000), nullable=False),
        sa.Column("description_html", sa.Text(), server_default=""),
        sa.Column("description_text", sa.Text(), server_default=""),
        sa.Column("due_at", sa.DateTime(timezone=True)),
        sa.Column("points_possible", sa.Float()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_assignments_canvas_id", "assignments", ["canvas_id"])

    op.create_table(
        "content_chunks",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "module_id", sa.UUID(), sa.ForeignKey("modules.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "source_type",
            sa.Enum("announcement", "assignment", "file", "page", name="sourcetype"),
            nullable=False,
        ),
        sa.Column("source_id", sa.String(255), nullable=False),
        sa.Column("source_title", sa.String(1000), nullable=False),
        sa.Column("source_url", sa.String(2048), server_default=""),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("token_count", sa.Integer(), nullable=False),
        sa.Column("embedding", Vector(1536)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )

    op.create_table(
        "tasks",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "module_id", sa.UUID(), sa.ForeignKey("modules.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("title", sa.String(1000), nullable=False),
        sa.Column(
            "task_type",
            sa.Enum("assignment", "quiz", "tutorial", "exam", "custom", name="tasktype"),
            nullable=False,
        ),
        sa.Column("due_at", sa.DateTime(timezone=True)),
        sa.Column("completed", sa.Boolean(), server_default="false"),
        sa.Column("source_type", sa.String(50), server_default=""),
        sa.Column("source_id", sa.String(255), server_default=""),
        sa.Column("source_url", sa.String(2048), server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )


def downgrade() -> None:
    op.drop_table("tasks")
    op.drop_table("content_chunks")
    op.drop_table("assignments")
    op.drop_table("announcements")
    op.drop_table("modules")
    op.drop_table("users")
    op.execute("DROP TYPE IF EXISTS sourcetype")
    op.execute("DROP TYPE IF EXISTS tasktype")
