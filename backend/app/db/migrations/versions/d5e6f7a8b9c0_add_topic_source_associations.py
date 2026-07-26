"""add durable topic source evidence associations

Revision ID: d5e6f7a8b9c0
Revises: c4d5e6f7a8b9
Create Date: 2026-07-27 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "d5e6f7a8b9c0"
down_revision: str | Sequence[str] | None = "c4d5e6f7a8b9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_unique_constraint(
        "uq_curriculum_topics_id_enrollment", "curriculum_topics", ["id", "enrollment_id"]
    )
    op.create_table(
        "topic_source_associations",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "enrollment_id",
            sa.Uuid(),
            sa.ForeignKey("module_enrollments.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("topic_id", sa.Uuid(), nullable=False),
        sa.Column(
            "source_id",
            sa.Uuid(),
            sa.ForeignKey("sources.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("method", sa.String(16), nullable=False),
        sa.Column("evidence_strength", sa.Float(), nullable=False),
        sa.Column("algorithm", sa.String(64), nullable=False),
        sa.Column("rule_hash", sa.String(64), nullable=False),
        sa.Column("source_fingerprint", sa.String(64), nullable=False),
        sa.Column("topic_fingerprint", sa.String(64), nullable=False),
        sa.Column(
            "evidence", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False
        ),
        sa.Column("reason_code", sa.String(64), nullable=False),
        sa.Column("stale", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("stale_reason", sa.String(64)),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("reviewed_at", sa.DateTime(timezone=True)),
        sa.Column("reviewer_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE")),
        sa.ForeignKeyConstraint(
            ["topic_id", "enrollment_id"],
            ["curriculum_topics.id", "curriculum_topics.enrollment_id"],
            ondelete="CASCADE",
            name="fk_topic_source_associations_topic_enrollment",
        ),
        sa.CheckConstraint(
            "status IN ('proposed', 'confirmed', 'rejected')",
            name="ck_topic_source_associations_status",
        ),
        sa.CheckConstraint(
            "method IN ('deterministic', 'manual')",
            name="ck_topic_source_associations_method",
        ),
        sa.CheckConstraint(
            "evidence_strength >= 0 AND evidence_strength <= 1",
            name="ck_topic_source_associations_strength",
        ),
        sa.CheckConstraint("length(rule_hash) = 64", name="ck_topic_source_associations_rule_hash"),
        sa.CheckConstraint(
            "length(source_fingerprint) = 64",
            name="ck_topic_source_associations_source_fingerprint",
        ),
        sa.CheckConstraint(
            "length(topic_fingerprint) = 64",
            name="ck_topic_source_associations_topic_fingerprint",
        ),
        sa.CheckConstraint(
            "(status = 'proposed' AND reviewed_at IS NULL AND reviewer_id IS NULL) OR "
            "(status IN ('confirmed', 'rejected') AND reviewed_at IS NOT NULL AND reviewer_id IS NOT NULL)",
            name="ck_topic_source_associations_review",
        ),
    )
    op.create_index(
        "uq_topic_source_associations_topic_source",
        "topic_source_associations",
        ["topic_id", "source_id"],
        unique=True,
    )
    op.create_index(
        "ix_topic_source_associations_enrollment_status",
        "topic_source_associations",
        ["enrollment_id", "status"],
    )
    op.create_index(
        "ix_topic_source_associations_source",
        "topic_source_associations",
        ["source_id"],
    )


def downgrade() -> None:
    op.drop_table("topic_source_associations")
    op.drop_constraint("uq_curriculum_topics_id_enrollment", "curriculum_topics", type_="unique")
