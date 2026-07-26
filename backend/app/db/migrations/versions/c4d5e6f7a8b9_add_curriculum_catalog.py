"""add provider-independent curriculum catalog

Revision ID: c4d5e6f7a8b9
Revises: b3c4d5e6f7a8
Create Date: 2026-07-26 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "c4d5e6f7a8b9"
down_revision: str | Sequence[str] | None = "b3c4d5e6f7a8"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _timestamps() -> list[sa.Column]:
    return [
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    ]


def _json_object() -> sa.TextClause:
    return sa.text("'{}'::jsonb")


def upgrade() -> None:
    op.create_table(
        "catalog_modules",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("institution", sa.String(100), nullable=False),
        sa.Column("canonical_code", sa.String(32), nullable=False),
        sa.Column("code", sa.String(32), nullable=False),
        sa.Column("title", sa.String(500), nullable=False),
        sa.Column("description", sa.Text(), server_default="", nullable=False),
        sa.Column(
            "metadata_json", postgresql.JSONB(), server_default=_json_object(), nullable=False
        ),
        *_timestamps(),
    )
    op.create_index(
        "uq_catalog_modules_institution_code",
        "catalog_modules",
        ["institution", "canonical_code"],
        unique=True,
    )
    op.create_table(
        "provider_module_snapshots",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("provider", sa.String(32), nullable=False),
        sa.Column("academic_year", sa.String(9), nullable=False),
        sa.Column("module_code", sa.String(32), nullable=False),
        sa.Column("provider_version", sa.String(32), nullable=False),
        sa.Column("source_url", sa.String(1000), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payload_sha256", sa.String(64), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.CheckConstraint(
            "length(payload_sha256) = 64", name="ck_provider_module_snapshots_payload_sha256"
        ),
    )
    op.create_table(
        "semester_offerings",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "catalog_module_id",
            sa.Uuid(),
            sa.ForeignKey("catalog_modules.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "provider_snapshot_id",
            sa.Uuid(),
            sa.ForeignKey("provider_module_snapshots.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("academic_year", sa.String(9), nullable=False),
        sa.Column("semester", sa.Integer(), nullable=False),
        sa.Column("available", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column(
            "metadata_json", postgresql.JSONB(), server_default=_json_object(), nullable=False
        ),
        sa.CheckConstraint(
            "academic_year ~ '^[0-9]{4}-[0-9]{4}$' AND "
            "substring(academic_year from 6 for 4)::integer = "
            "substring(academic_year from 1 for 4)::integer + 1 AND "
            "substring(academic_year from 1 for 4)::integer BETWEEN 2000 AND 2100",
            name="ck_semester_offerings_academic_year",
        ),
        sa.CheckConstraint("semester BETWEEN 1 AND 4", name="ck_semester_offerings_semester"),
        *_timestamps(),
    )
    op.create_index(
        "uq_semester_offerings_module_year_semester",
        "semester_offerings",
        ["catalog_module_id", "academic_year", "semester"],
        unique=True,
    )
    op.create_table(
        "module_enrollments",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "offering_id",
            sa.Uuid(),
            sa.ForeignKey("semester_offerings.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("provenance", sa.String(32), nullable=False),
        sa.Column("import_method", sa.String(32), nullable=False),
        sa.Column("topic_state", sa.String(16), nullable=False),
        sa.Column("evidence_warning", sa.Text()),
        sa.Column(
            "lesson_config", postgresql.JSONB(), server_default=_json_object(), nullable=False
        ),
        sa.Column("archived", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.CheckConstraint(
            "provenance IN ('nusmods', 'manual')", name="ck_module_enrollments_provenance"
        ),
        sa.CheckConstraint(
            "import_method IN ('share_url', 'manual_codes')",
            name="ck_module_enrollments_import_method",
        ),
        sa.CheckConstraint(
            "topic_state IN ('provisional', 'canonical')",
            name="ck_module_enrollments_topic_state",
        ),
        *_timestamps(),
    )
    op.create_index(
        "uq_module_enrollments_user_offering",
        "module_enrollments",
        ["user_id", "offering_id"],
        unique=True,
    )
    op.create_index("ix_module_enrollments_user", "module_enrollments", ["user_id"])
    op.add_column("user_preferences", sa.Column("default_enrollment_id", sa.Uuid()))
    op.create_foreign_key(
        "fk_user_preferences_default_enrollment_id",
        "user_preferences",
        "module_enrollments",
        ["default_enrollment_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.add_column("sources", sa.Column("enrollment_id", sa.Uuid()))
    op.create_foreign_key(
        "fk_sources_enrollment_id",
        "sources",
        "module_enrollments",
        ["enrollment_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index("ix_sources_enrollment_id", "sources", ["enrollment_id"])
    op.create_table(
        "module_import_previews",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("provider", sa.String(32), server_default="nusmods", nullable=False),
        sa.Column("import_method", sa.String(32), nullable=False),
        sa.Column("academic_year", sa.String(9), nullable=False),
        sa.Column("semester", sa.Integer(), nullable=False),
        sa.Column(
            "reconciliation", postgresql.JSONB(), server_default=_json_object(), nullable=False
        ),
        sa.Column("commit_request", postgresql.JSONB()),
        sa.Column("commit_result", postgresql.JSONB()),
        sa.Column("committed_at", sa.DateTime(timezone=True)),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "expires_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now() + interval '30 minutes'"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "academic_year ~ '^[0-9]{4}-[0-9]{4}$' AND "
            "substring(academic_year from 6 for 4)::integer = "
            "substring(academic_year from 1 for 4)::integer + 1 AND "
            "substring(academic_year from 1 for 4)::integer BETWEEN 2000 AND 2100",
            name="ck_module_import_previews_academic_year",
        ),
        sa.CheckConstraint("semester BETWEEN 1 AND 4", name="ck_module_import_previews_semester"),
        sa.CheckConstraint(
            "import_method IN ('share_url', 'manual_codes')",
            name="ck_module_import_previews_import_method",
        ),
        sa.CheckConstraint(
            "(committed_at IS NULL AND commit_request IS NULL AND commit_result IS NULL) OR "
            "(committed_at IS NOT NULL AND commit_request IS NOT NULL AND commit_result IS NOT NULL)",
            name="ck_module_import_previews_commit_snapshot",
        ),
    )
    op.create_index(
        "ix_module_import_previews_user_created",
        "module_import_previews",
        ["user_id", "created_at"],
    )
    op.create_table(
        "module_import_items",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "preview_id",
            sa.Uuid(),
            sa.ForeignKey("module_import_previews.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("code", sa.String(32), nullable=False),
        sa.Column("title", sa.String(500), server_default="", nullable=False),
        sa.Column("available", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("disposition", sa.String(32), nullable=False),
        sa.Column(
            "lesson_config", postgresql.JSONB(), server_default=_json_object(), nullable=False
        ),
        sa.Column("detail_snapshot", postgresql.JSONB()),
        sa.Column("provider_version", sa.String(32)),
        sa.Column("source_url", sa.String(1000)),
        sa.Column("fetched_at", sa.DateTime(timezone=True)),
        sa.Column("payload_sha256", sa.String(64)),
        sa.CheckConstraint("position >= 0", name="ck_module_import_items_position"),
        sa.CheckConstraint(
            "disposition IN ('import', 'already_enrolled', 'restore', 'unavailable', 'not_found')",
            name="ck_module_import_items_disposition",
        ),
        sa.CheckConstraint(
            "payload_sha256 IS NULL OR length(payload_sha256) = 64",
            name="ck_module_import_items_payload_sha256",
        ),
        sa.CheckConstraint(
            "(detail_snapshot IS NULL AND provider_version IS NULL AND source_url IS NULL "
            "AND fetched_at IS NULL AND payload_sha256 IS NULL) OR "
            "(detail_snapshot IS NOT NULL AND provider_version IS NOT NULL AND source_url IS NOT NULL "
            "AND fetched_at IS NOT NULL AND payload_sha256 IS NOT NULL)",
            name="ck_module_import_items_snapshot_complete",
        ),
    )
    op.create_index(
        "uq_module_import_items_preview_code",
        "module_import_items",
        ["preview_id", "code"],
        unique=True,
    )
    op.create_index(
        "uq_module_import_items_preview_position",
        "module_import_items",
        ["preview_id", "position"],
        unique=True,
    )
    op.create_table(
        "curriculum_topics",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "enrollment_id",
            sa.Uuid(),
            sa.ForeignKey("module_enrollments.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("title", sa.String(300), nullable=False),
        sa.Column("archived", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("state", sa.String(16), nullable=False),
        sa.Column("provenance", sa.String(64), nullable=False),
        sa.Column("extraction_rule", sa.String(32), nullable=False),
        sa.Column("extraction_rule_hash", sa.String(64), nullable=False),
        sa.Column("source_text", sa.Text(), nullable=False),
        sa.Column("source_sha256", sa.String(64), nullable=False),
        sa.CheckConstraint("position >= 0", name="ck_curriculum_topics_position"),
        sa.CheckConstraint(
            "state IN ('provisional', 'canonical')", name="ck_curriculum_topics_state"
        ),
        sa.CheckConstraint(
            "provenance IN ('catalog_description', 'user_review', 'syllabus')",
            name="ck_curriculum_topics_provenance",
        ),
        sa.CheckConstraint(
            "length(extraction_rule_hash) = 64", name="ck_curriculum_topics_rule_hash"
        ),
        sa.CheckConstraint("length(source_sha256) = 64", name="ck_curriculum_topics_source_hash"),
        *_timestamps(),
    )
    op.create_index(
        "uq_curriculum_topics_enrollment_position",
        "curriculum_topics",
        ["enrollment_id", "position"],
        unique=True,
    )
    op.create_index("ix_curriculum_topics_enrollment", "curriculum_topics", ["enrollment_id"])
    op.create_table(
        "topic_revisions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "enrollment_id",
            sa.Uuid(),
            sa.ForeignKey("module_enrollments.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("source_id", sa.Uuid(), sa.ForeignKey("sources.id", ondelete="SET NULL")),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("base_topics", postgresql.JSONB(), nullable=False),
        sa.Column("proposed_topics", postgresql.JSONB(), nullable=False),
        sa.Column("mapping", postgresql.JSONB(), server_default=_json_object(), nullable=False),
        sa.Column("algorithm", sa.String(32), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("reviewed_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint(
            "status IN ('pending', 'accepted', 'rejected')", name="ck_topic_revisions_status"
        ),
    )
    op.create_index(
        "ix_topic_revisions_enrollment_created", "topic_revisions", ["enrollment_id", "created_at"]
    )


def downgrade() -> None:
    op.drop_table("topic_revisions")
    op.drop_table("curriculum_topics")
    op.drop_table("module_import_items")
    op.drop_table("module_import_previews")
    op.drop_index("ix_sources_enrollment_id", table_name="sources")
    op.drop_constraint("fk_sources_enrollment_id", "sources", type_="foreignkey")
    op.drop_column("sources", "enrollment_id")
    op.drop_constraint(
        "fk_user_preferences_default_enrollment_id", "user_preferences", type_="foreignkey"
    )
    op.drop_column("user_preferences", "default_enrollment_id")
    op.drop_table("module_enrollments")
    op.drop_table("semester_offerings")
    op.drop_table("provider_module_snapshots")
    op.drop_table("catalog_modules")
