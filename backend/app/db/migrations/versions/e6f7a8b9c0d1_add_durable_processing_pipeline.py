"""add durable source processing pipeline

Revision ID: e6f7a8b9c0d1
Revises: d5e6f7a8b9c0
Create Date: 2026-07-28 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "e6f7a8b9c0d1"
down_revision: str | Sequence[str] | None = "d5e6f7a8b9c0"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "source_versions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "source_id", sa.Uuid(), sa.ForeignKey("sources.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("version_number", sa.Integer(), nullable=False),
        sa.Column("fingerprint", sa.String(64), nullable=False),
        sa.Column("filename", sa.String(255)),
        sa.Column(
            "payload", postgresql.JSONB(), server_default=sa.text("'{}'::jsonb"), nullable=False
        ),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("error", sa.Text()),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("ready_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("version_number > 0", name="ck_source_versions_number"),
        sa.CheckConstraint("length(fingerprint) = 64", name="ck_source_versions_fingerprint"),
        sa.CheckConstraint(
            "status IN ('pending', 'processing', 'ready', 'failed', 'cancelled')",
            name="ck_source_versions_status",
        ),
    )
    op.create_index(
        "uq_source_versions_source_number",
        "source_versions",
        ["source_id", "version_number"],
        unique=True,
    )
    op.create_index(
        "uq_source_versions_source_fingerprint",
        "source_versions",
        ["source_id", "fingerprint"],
        unique=True,
    )
    op.add_column("sources", sa.Column("current_version_id", sa.Uuid()))
    op.create_foreign_key(
        "fk_sources_current_version",
        "sources",
        "source_versions",
        ["current_version_id"],
        ["id"],
        ondelete="SET NULL",
    )

    op.create_table(
        "processing_policies",
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
        ),
        sa.Column("process_sources", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("map_topics", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("compile_wiki", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("flashcard_mode", sa.String(16), server_default="suggest", nullable=False),
        sa.Column("require_deck_review", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "flashcard_mode IN ('off', 'suggest', 'draft')",
            name="ck_processing_policies_flashcard_mode",
        ),
        sa.CheckConstraint("require_deck_review = true", name="ck_processing_policies_review_gate"),
    )
    op.create_table(
        "processing_runs",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "source_id", sa.Uuid(), sa.ForeignKey("sources.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "source_version_id",
            sa.Uuid(),
            sa.ForeignKey("source_versions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("idempotency_key", sa.String(128), nullable=False),
        sa.Column("causation_id", sa.Uuid()),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("current_stage", sa.String(32), nullable=False),
        sa.Column(
            "policy_snapshot",
            postgresql.JSONB(),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.Column("attempt_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column(
            "next_attempt_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.Column("cancelled_at", sa.DateTime(timezone=True)),
        sa.Column("pause_reason", sa.String(64)),
        sa.Column("error_code", sa.String(64)),
        sa.Column("error", sa.Text()),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "status IN ('queued', 'running', 'paused', 'ready', 'failed', 'cancelled')",
            name="ck_processing_runs_status",
        ),
    )
    op.create_index(
        "uq_processing_runs_user_key",
        "processing_runs",
        ["user_id", "idempotency_key"],
        unique=True,
    )
    op.create_index(
        "ix_processing_runs_claim", "processing_runs", ["status", "next_attempt_at", "created_at"]
    )
    op.create_index("ix_processing_runs_source", "processing_runs", ["source_id", "created_at"])
    op.create_table(
        "processing_enqueue_requests",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "run_id",
            sa.Uuid(),
            sa.ForeignKey("processing_runs.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "source_version_id",
            sa.Uuid(),
            sa.ForeignKey("source_versions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("idempotency_key", sa.String(128), nullable=False),
        sa.Column("request_hash", sa.String(64), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index(
        "uq_processing_enqueue_requests_user_key",
        "processing_enqueue_requests",
        ["user_id", "idempotency_key"],
        unique=True,
    )
    op.create_table(
        "processing_stages",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "run_id",
            sa.Uuid(),
            sa.ForeignKey("processing_runs.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("name", sa.String(32), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("attempt_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("max_attempts", sa.Integer(), nullable=False),
        sa.Column(
            "available_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("lease_owner", sa.String(128)),
        sa.Column("lease_token", sa.Integer(), server_default="0", nullable=False),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True)),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.Column("input_fingerprint", sa.String(64)),
        sa.Column("output_fingerprint", sa.String(64)),
        sa.Column(
            "outcome", postgresql.JSONB(), server_default=sa.text("'{}'::jsonb"), nullable=False
        ),
        sa.Column("error_code", sa.String(64)),
        sa.Column("error", sa.Text()),
        sa.UniqueConstraint("run_id", "name", name="uq_processing_stages_run_name"),
        sa.CheckConstraint(
            "attempt_count >= 0 AND max_attempts > 0", name="ck_processing_stages_attempts"
        ),
        sa.CheckConstraint(
            "status IN ('blocked', 'queued', 'running', 'paused', 'succeeded', 'skipped', 'failed', 'cancelled')",
            name="ck_processing_stages_status",
        ),
    )
    op.create_index(
        "ix_processing_stages_claim", "processing_stages", ["status", "available_at", "position"]
    )
    op.create_table(
        "processing_coverage_snapshots",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "run_id",
            sa.Uuid(),
            sa.ForeignKey("processing_runs.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "enrollment_id",
            sa.Uuid(),
            sa.ForeignKey("module_enrollments.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "source_version_id",
            sa.Uuid(),
            sa.ForeignKey("source_versions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("fingerprint", sa.String(64), nullable=False),
        sa.Column("snapshot", postgresql.JSONB(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("length(fingerprint) = 64", name="ck_processing_coverage_fingerprint"),
    )
    op.create_index(
        "uq_processing_coverage_source_version",
        "processing_coverage_snapshots",
        ["enrollment_id", "source_version_id"],
        unique=True,
    )
    op.create_table(
        "processing_events",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "run_id",
            sa.Uuid(),
            sa.ForeignKey("processing_runs.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("stage_id", sa.Uuid(), sa.ForeignKey("processing_stages.id", ondelete="CASCADE")),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("event_type", sa.String(64), nullable=False),
        sa.Column("dedupe_key", sa.String(128), nullable=False),
        sa.Column(
            "payload", postgresql.JSONB(), server_default=sa.text("'{}'::jsonb"), nullable=False
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index(
        "uq_processing_events_run_key", "processing_events", ["run_id", "dedupe_key"], unique=True
    )
    op.create_index(
        "ix_processing_events_user_created", "processing_events", ["user_id", "created_at"]
    )

    op.drop_index("uq_source_chunks_source_index", table_name="source_chunks")
    op.add_column("source_chunks", sa.Column("source_version_id", sa.Uuid()))
    op.add_column("source_chunks", sa.Column("fingerprint", sa.String(64)))
    op.execute(
        "UPDATE source_chunks SET fingerprint = "
        "md5(source_id::text || ':' || chunk_index::text || ':' || content || ':' || citation_ref) || "
        "md5(location_label || ':' || token_count::text) "
        "WHERE source_version_id IS NULL"
    )
    op.create_foreign_key(
        "fk_source_chunks_version",
        "source_chunks",
        "source_versions",
        ["source_version_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_unique_constraint(
        "uq_source_chunks_version_index", "source_chunks", ["source_version_id", "chunk_index"]
    )
    op.create_index("ix_source_chunks_fingerprint", "source_chunks", ["fingerprint"])
    op.add_column("wiki_pages", sa.Column("input_fingerprint", sa.String(64)))
    op.add_column(
        "flashcard_decks",
        sa.Column("lifecycle", sa.String(20), server_default="published", nullable=False),
    )
    op.add_column("flashcard_decks", sa.Column("input_fingerprint", sa.String(64)))
    op.create_check_constraint(
        "ck_flashcard_decks_lifecycle",
        "flashcard_decks",
        "lifecycle IN ('draft', 'published', 'archived')",
    )
    op.create_index(
        "uq_flashcard_decks_user_fingerprint",
        "flashcard_decks",
        ["user_id", "input_fingerprint"],
        unique=True,
        postgresql_where=sa.text("input_fingerprint IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_flashcard_decks_user_fingerprint", table_name="flashcard_decks")
    op.drop_constraint("ck_flashcard_decks_lifecycle", "flashcard_decks", type_="check")
    op.drop_column("flashcard_decks", "input_fingerprint")
    op.drop_column("flashcard_decks", "lifecycle")
    op.drop_column("wiki_pages", "input_fingerprint")
    op.drop_index("ix_source_chunks_fingerprint", table_name="source_chunks")
    op.drop_constraint("uq_source_chunks_version_index", "source_chunks", type_="unique")
    op.drop_constraint("fk_source_chunks_version", "source_chunks", type_="foreignkey")
    op.drop_column("source_chunks", "fingerprint")
    op.drop_column("source_chunks", "source_version_id")
    op.create_index(
        "uq_source_chunks_source_index", "source_chunks", ["source_id", "chunk_index"], unique=True
    )
    op.drop_table("processing_events")
    op.drop_table("processing_coverage_snapshots")
    op.drop_table("processing_stages")
    op.drop_table("processing_enqueue_requests")
    op.drop_table("processing_runs")
    op.drop_table("processing_policies")
    op.drop_constraint("fk_sources_current_version", "sources", type_="foreignkey")
    op.drop_column("sources", "current_version_id")
    op.drop_table("source_versions")
