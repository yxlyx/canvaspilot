"""add ingestion jobs

Revision ID: c4d2f0e9a8b1
Revises: b2a91f5d4c0e
Create Date: 2026-06-19 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "c4d2f0e9a8b1"
down_revision: str | Sequence[str] | None = "b2a91f5d4c0e"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


job_status = postgresql.ENUM(
    "queued",
    "running",
    "completed",
    "failed",
    "cancelled",
    name="ingestionjobstatus",
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    job_status.create(bind, checkfirst=True)

    op.create_table(
        "ingestion_jobs",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("status", job_status, nullable=False, server_default="queued"),
        sa.Column(
            "source_ids",
            postgresql.ARRAY(sa.UUID()),
            nullable=False,
            server_default=sa.text("'{}'::uuid[]"),
        ),
        sa.Column("batch_key", sa.String(64), nullable=False),
        sa.Column("source_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("imported_source_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("chunk_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("error_message", sa.Text()),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_ingestion_jobs_user_status", "ingestion_jobs", ["user_id", "status"])
    op.create_index(
        "ix_ingestion_jobs_user_created_at",
        "ingestion_jobs",
        ["user_id", "created_at"],
    )
    op.create_index(
        "ix_ingestion_jobs_user_batch_key",
        "ingestion_jobs",
        ["user_id", "batch_key"],
    )
    op.create_index(
        "uq_ingestion_jobs_active_batch",
        "ingestion_jobs",
        ["user_id", "batch_key"],
        unique=True,
        postgresql_where=sa.text("status IN ('queued', 'running')"),
    )


def downgrade() -> None:
    op.drop_index("uq_ingestion_jobs_active_batch", table_name="ingestion_jobs")
    op.drop_index("ix_ingestion_jobs_user_batch_key", table_name="ingestion_jobs")
    op.drop_index("ix_ingestion_jobs_user_created_at", table_name="ingestion_jobs")
    op.drop_index("ix_ingestion_jobs_user_status", table_name="ingestion_jobs")
    op.drop_table("ingestion_jobs")
    job_status.drop(op.get_bind(), checkfirst=True)
