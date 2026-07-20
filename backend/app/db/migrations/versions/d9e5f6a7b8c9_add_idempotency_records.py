"""add durable idempotency records

Revision ID: d9e5f6a7b8c9
Revises: c8d4e5f6a7b8
Create Date: 2026-07-21 00:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "d9e5f6a7b8c9"
down_revision: str | Sequence[str] | None = "c8d4e5f6a7b8"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_index("ix_study_outputs_user_created", table_name="study_outputs")
    op.create_index(
        "ix_study_outputs_user_created", "study_outputs", ["user_id", "created_at", "id"]
    )
    op.drop_index("ix_marked_papers_user_created", table_name="marked_papers")
    op.create_index(
        "ix_marked_papers_user_created", "marked_papers", ["user_id", "created_at", "id"]
    )
    op.create_table(
        "idempotency_records",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("idempotency_key", sa.String(128), nullable=False),
        sa.Column("operation", sa.String(200), nullable=False),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column("response_status", sa.Integer(), nullable=True),
        sa.Column("response_body", postgresql.JSONB(), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "expires_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now() + interval '24 hours'"),
            nullable=False,
        ),
    )
    op.create_index(
        "uq_idempotency_records_user_key",
        "idempotency_records",
        ["user_id", "idempotency_key"],
        unique=True,
    )
    op.create_index("ix_idempotency_records_created_at", "idempotency_records", ["created_at"])
    op.create_index("ix_idempotency_records_expires_at", "idempotency_records", ["expires_at"])


def downgrade() -> None:
    op.drop_index("ix_idempotency_records_expires_at", table_name="idempotency_records")
    op.drop_index("ix_idempotency_records_created_at", table_name="idempotency_records")
    op.drop_index("uq_idempotency_records_user_key", table_name="idempotency_records")
    op.drop_table("idempotency_records")
    op.drop_index("ix_marked_papers_user_created", table_name="marked_papers")
    op.create_index("ix_marked_papers_user_created", "marked_papers", ["user_id", "created_at"])
    op.drop_index("ix_study_outputs_user_created", table_name="study_outputs")
    op.create_index("ix_study_outputs_user_created", "study_outputs", ["user_id", "created_at"])
