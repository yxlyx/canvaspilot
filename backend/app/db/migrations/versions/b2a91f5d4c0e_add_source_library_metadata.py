"""add source library metadata

Revision ID: b2a91f5d4c0e
Revises: 7a9c2f1e4b6d
Create Date: 2026-06-19 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "b2a91f5d4c0e"
down_revision: str | Sequence[str] | None = "7a9c2f1e4b6d"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


source_kind = postgresql.ENUM(
    "markdown",
    "plain_text",
    "pdf",
    "link",
    "repository",
    name="librarysourcetype",
    create_type=False,
)
source_status = postgresql.ENUM(
    "pending",
    "indexing",
    "ready",
    "failed",
    "archived",
    name="sourcestatus",
    create_type=False,
)


def upgrade() -> None:
    bind = op.get_bind()
    source_kind.create(bind, checkfirst=True)
    source_status.create(bind, checkfirst=True)

    op.create_table(
        "sources",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("source_type", source_kind, nullable=False),
        sa.Column("origin", sa.String(255), nullable=False),
        sa.Column("external_id", sa.String(512)),
        sa.Column("title", sa.String(1000), nullable=False),
        sa.Column("source_url", sa.String(2048), nullable=False, server_default=""),
        sa.Column("citation_label", sa.String(1000), nullable=False),
        sa.Column(
            "topic_tags",
            postgresql.ARRAY(sa.String(100)),
            nullable=False,
            server_default=sa.text("'{}'::character varying[]"),
        ),
        sa.Column("status", source_status, nullable=False, server_default="pending"),
        sa.Column("course_context", sa.String(255)),
        sa.Column("project_context", sa.String(255)),
        sa.Column("last_imported_at", sa.DateTime(timezone=True)),
        sa.Column("import_error", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_sources_user_updated_at", "sources", ["user_id", "updated_at"])
    op.create_index("ix_sources_user_source_type", "sources", ["user_id", "source_type"])
    op.create_index("ix_sources_user_status", "sources", ["user_id", "status"])
    op.create_index("ix_sources_user_title", "sources", ["user_id", "title"])
    op.create_index("ix_sources_topic_tags", "sources", ["topic_tags"], postgresql_using="gin")
    op.create_index(
        "uq_sources_user_origin_external",
        "sources",
        ["user_id", "origin", "external_id"],
        unique=True,
        postgresql_where=sa.text("external_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_sources_user_origin_external", table_name="sources")
    op.drop_index("ix_sources_topic_tags", table_name="sources")
    op.drop_index("ix_sources_user_title", table_name="sources")
    op.drop_index("ix_sources_user_status", table_name="sources")
    op.drop_index("ix_sources_user_source_type", table_name="sources")
    op.drop_index("ix_sources_user_updated_at", table_name="sources")
    op.drop_table("sources")
    bind = op.get_bind()
    source_status.drop(bind, checkfirst=True)
    source_kind.drop(bind, checkfirst=True)
