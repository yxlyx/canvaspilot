"""add milestone 3 backend services

Revision ID: c8d4e5f6a7b8
Revises: b7c2d3e4f5a6
Create Date: 2026-07-20 00:00:00.000000
"""

import uuid
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "c8d4e5f6a7b8"
down_revision: str | Sequence[str] | None = "b7c2d3e4f5a6"
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


def upgrade() -> None:
    op.add_column(
        "wiki_pages",
        sa.Column("is_current", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.create_table(
        "study_outputs",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("output_type", sa.String(50), nullable=False),
        sa.Column("title", sa.String(300), nullable=False),
        sa.Column("status", sa.String(50), nullable=False),
        sa.Column("content", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "source_ids",
            postgresql.ARRAY(sa.UUID()),
            nullable=False,
            server_default=sa.text("'{}'::uuid[]"),
        ),
        sa.Column("wiki_page_id", sa.UUID(), sa.ForeignKey("wiki_pages.id", ondelete="SET NULL")),
        sa.Column("message", sa.Text(), nullable=False, server_default=""),
        *_timestamps(),
    )
    op.create_index("ix_study_outputs_user_created", "study_outputs", ["user_id", "created_at"])
    op.create_table(
        "study_output_citations",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "output_id",
            sa.UUID(),
            sa.ForeignKey("study_outputs.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "source_id", sa.UUID(), sa.ForeignKey("sources.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "source_chunk_id", sa.UUID(), sa.ForeignKey("source_chunks.id", ondelete="SET NULL")
        ),
        sa.Column("citation_key", sa.String(64), nullable=False),
        sa.Column("citation_ref", sa.String(1000), nullable=False),
        sa.Column("source_title", sa.String(1000), nullable=False),
        sa.Column("snippet", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index("ix_study_output_citations_output", "study_output_citations", ["output_id"])

    op.create_table(
        "wiki_revisions",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("page_id", sa.UUID(), nullable=False),
        sa.Column("revision_number", sa.Integer(), nullable=False),
        sa.Column("title", sa.String(1000), nullable=False),
        sa.Column("markdown", sa.Text(), nullable=False),
        sa.Column(
            "source_ids",
            postgresql.ARRAY(sa.UUID()),
            nullable=False,
            server_default=sa.text("'{}'::uuid[]"),
        ),
        sa.Column("citation_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("change_summary", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index("ix_wiki_revisions_user_created", "wiki_revisions", ["user_id", "created_at"])
    op.create_index(
        "uq_wiki_revisions_page_number",
        "wiki_revisions",
        ["page_id", "revision_number"],
        unique=True,
    )
    pages = (
        op.get_bind()
        .execute(
            sa.text(
                "SELECT id, user_id, title, markdown, source_ids, citation_count, created_at "
                "FROM wiki_pages"
            )
        )
        .mappings()
    )
    revision_table = sa.table(
        "wiki_revisions",
        sa.column("id", sa.UUID()),
        sa.column("user_id", sa.UUID()),
        sa.column("page_id", sa.UUID()),
        sa.column("revision_number", sa.Integer()),
        sa.column("title", sa.String()),
        sa.column("markdown", sa.Text()),
        sa.column("source_ids", postgresql.ARRAY(sa.UUID())),
        sa.column("citation_count", sa.Integer()),
        sa.column("change_summary", sa.Text()),
        sa.column("created_at", sa.DateTime(timezone=True)),
    )
    op.bulk_insert(
        revision_table,
        [
            {
                "id": uuid.uuid4(),
                "user_id": page["user_id"],
                "page_id": page["id"],
                "revision_number": 1,
                "title": page["title"],
                "markdown": page["markdown"],
                "source_ids": page["source_ids"],
                "citation_count": page["citation_count"],
                "change_summary": "State preserved during revision migration",
                "created_at": page["created_at"],
            }
            for page in pages
        ],
    )

    op.create_table(
        "source_changes",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("source_id", sa.UUID(), nullable=False),
        sa.Column("source_title", sa.String(1000), nullable=False, server_default=""),
        sa.Column("change_type", sa.String(50), nullable=False),
        sa.Column(
            "before_snapshot",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column(
            "after_snapshot",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index("ix_source_changes_user_created", "source_changes", ["user_id", "created_at"])

    op.create_table(
        "health_findings",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("code", sa.String(50), nullable=False),
        sa.Column("severity", sa.String(20), nullable=False),
        sa.Column("state", sa.String(20), nullable=False),
        sa.Column("resource_type", sa.String(50), nullable=False),
        sa.Column("resource_id", sa.UUID()),
        sa.Column("topic", sa.String(100)),
        sa.Column("message", sa.Text(), nullable=False),
        sa.Column("recommendation", sa.Text(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index("ix_health_findings_user_created", "health_findings", ["user_id", "created_at"])

    op.create_table(
        "marked_papers",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("filename", sa.String(255), nullable=False),
        sa.Column("content_type", sa.String(100), nullable=False),
        sa.Column("raw_content", sa.LargeBinary(), nullable=False),
        sa.Column(
            "extraction_status", sa.String(50), nullable=False, server_default="pending_review"
        ),
        sa.Column("extraction_message", sa.Text(), nullable=False, server_default=""),
        *_timestamps(),
    )
    op.create_index("ix_marked_papers_user_created", "marked_papers", ["user_id", "created_at"])
    op.create_table(
        "marked_paper_questions",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "paper_id",
            sa.UUID(),
            sa.ForeignKey("marked_papers.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("question_number", sa.Integer(), nullable=False),
        sa.Column("question_text", sa.Text(), nullable=False),
        sa.Column("awarded_marks", sa.Float()),
        sa.Column("available_marks", sa.Float()),
        sa.Column("feedback", sa.Text(), nullable=False, server_default=""),
        sa.Column("topic_tag", sa.String(100), nullable=False, server_default="general"),
        sa.Column("confidence", sa.Float(), nullable=False, server_default="0.5"),
        sa.Column("reviewed", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("reviewed_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint(
            "(awarded_marks IS NULL OR awarded_marks >= 0) AND "
            "(available_marks IS NULL OR available_marks > 0) AND "
            "(awarded_marks IS NULL OR available_marks IS NULL "
            "OR awarded_marks <= available_marks)",
            name="ck_marked_question_marks",
        ),
    )
    op.create_index("ix_marked_questions_paper", "marked_paper_questions", ["paper_id"])
    op.create_index(
        "uq_marked_questions_paper_number",
        "marked_paper_questions",
        ["paper_id", "question_number"],
        unique=True,
    )
    op.add_column("learning_evidence", sa.Column("marked_paper_question_id", sa.UUID()))
    op.create_foreign_key(
        "fk_learning_evidence_marked_question",
        "learning_evidence",
        "marked_paper_questions",
        ["marked_paper_question_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_index(
        "uq_learning_evidence_marked_question",
        "learning_evidence",
        ["marked_paper_question_id"],
        unique=True,
        postgresql_where=sa.text("marked_paper_question_id IS NOT NULL"),
    )

    op.create_table(
        "provider_settings",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("provider", sa.String(50), nullable=False),
        sa.Column("model", sa.String(100), nullable=False),
        sa.Column("endpoint", sa.String(500), nullable=False),
        sa.Column("encrypted_api_key", sa.LargeBinary(), nullable=False),
        sa.Column("encryption_key_id", sa.String(100), nullable=False),
        sa.Column("status", sa.String(50), nullable=False, server_default="configured"),
        sa.Column("last_tested_at", sa.DateTime(timezone=True)),
        *_timestamps(),
    )
    op.create_index(
        "uq_provider_settings_user_provider",
        "provider_settings",
        ["user_id", "provider"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("uq_provider_settings_user_provider", table_name="provider_settings")
    op.drop_table("provider_settings")
    op.drop_index("uq_learning_evidence_marked_question", table_name="learning_evidence")
    op.drop_constraint(
        "fk_learning_evidence_marked_question", "learning_evidence", type_="foreignkey"
    )
    op.drop_column("learning_evidence", "marked_paper_question_id")
    op.drop_index("uq_marked_questions_paper_number", table_name="marked_paper_questions")
    op.drop_index("ix_marked_questions_paper", table_name="marked_paper_questions")
    op.drop_table("marked_paper_questions")
    op.drop_index("ix_marked_papers_user_created", table_name="marked_papers")
    op.drop_table("marked_papers")
    op.drop_index("ix_health_findings_user_created", table_name="health_findings")
    op.drop_table("health_findings")
    op.drop_index("ix_source_changes_user_created", table_name="source_changes")
    op.drop_table("source_changes")
    op.drop_index("uq_wiki_revisions_page_number", table_name="wiki_revisions")
    op.drop_index("ix_wiki_revisions_user_created", table_name="wiki_revisions")
    op.drop_table("wiki_revisions")
    op.drop_index("ix_study_output_citations_output", table_name="study_output_citations")
    op.drop_table("study_output_citations")
    op.drop_index("ix_study_outputs_user_created", table_name="study_outputs")
    op.drop_table("study_outputs")
    op.drop_column("wiki_pages", "is_current")
