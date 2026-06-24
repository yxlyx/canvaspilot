"""add wiki pages

Revision ID: a8c1d2e3f4b5
Revises: f6a7b8c9d0e1
Create Date: 2026-06-21 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "a8c1d2e3f4b5"
down_revision: str | Sequence[str] | None = "f6a7b8c9d0e1"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "wiki_pages",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("slug", sa.String(255), nullable=False),
        sa.Column("title", sa.String(1000), nullable=False),
        sa.Column("page_type", sa.String(50), nullable=False, server_default="source"),
        sa.Column("markdown", sa.Text(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "source_ids",
            postgresql.ARRAY(sa.UUID()),
            nullable=False,
            server_default=sa.text("'{}'::uuid[]"),
        ),
        sa.Column("citation_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column(
            "backlinks",
            postgresql.ARRAY(sa.String(255)),
            nullable=False,
            server_default=sa.text("'{}'::character varying[]"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_wiki_pages_user_slug", "wiki_pages", ["user_id", "slug"], unique=True)
    op.create_index("ix_wiki_pages_user_updated_at", "wiki_pages", ["user_id", "updated_at"])
    op.create_index(
        "ix_wiki_pages_source_ids", "wiki_pages", ["source_ids"], postgresql_using="gin"
    )

    op.create_table(
        "wiki_citations",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "page_id",
            sa.UUID(),
            sa.ForeignKey("wiki_pages.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "source_id", sa.UUID(), sa.ForeignKey("sources.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "source_chunk_id",
            sa.UUID(),
            sa.ForeignKey("source_chunks.id", ondelete="SET NULL"),
        ),
        sa.Column("citation_key", sa.String(64), nullable=False),
        sa.Column("citation_ref", sa.String(1000), nullable=False),
        sa.Column("source_title", sa.String(1000), nullable=False),
        sa.Column("location_label", sa.String(255), nullable=False, server_default=""),
        sa.Column("chunk_index", sa.Integer()),
        sa.Column("snippet", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_wiki_citations_page_id", "wiki_citations", ["page_id"])
    op.create_index("ix_wiki_citations_source_id", "wiki_citations", ["source_id"])
    op.create_index("ix_wiki_citations_source_chunk_id", "wiki_citations", ["source_chunk_id"])


def downgrade() -> None:
    op.drop_index("ix_wiki_citations_source_chunk_id", table_name="wiki_citations")
    op.drop_index("ix_wiki_citations_source_id", table_name="wiki_citations")
    op.drop_index("ix_wiki_citations_page_id", table_name="wiki_citations")
    op.drop_table("wiki_citations")
    op.drop_index("ix_wiki_pages_source_ids", table_name="wiki_pages")
    op.drop_index("ix_wiki_pages_user_updated_at", table_name="wiki_pages")
    op.drop_index("ix_wiki_pages_user_slug", table_name="wiki_pages")
    op.drop_table("wiki_pages")
