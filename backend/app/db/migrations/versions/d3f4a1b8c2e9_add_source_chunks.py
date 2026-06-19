"""add source chunks

Revision ID: d3f4a1b8c2e9
Revises: c4d2f0e9a8b1
Create Date: 2026-06-19 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from pgvector.sqlalchemy import Vector

revision: str = "d3f4a1b8c2e9"
down_revision: str | Sequence[str] | None = "c4d2f0e9a8b1"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "source_chunks",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "source_id", sa.UUID(), sa.ForeignKey("sources.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("chunk_index", sa.Integer(), nullable=False),
        sa.Column("citation_ref", sa.String(1000), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("token_count", sa.Integer(), nullable=False),
        sa.Column("embedding", Vector(1536)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_source_chunks_source_id", "source_chunks", ["source_id"])
    op.create_index(
        "uq_source_chunks_source_index",
        "source_chunks",
        ["source_id", "chunk_index"],
        unique=True,
    )
    op.execute(
        """
        CREATE INDEX ix_source_chunks_embedding ON source_chunks
        USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
        """
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_source_chunks_embedding")
    op.drop_index("uq_source_chunks_source_index", table_name="source_chunks")
    op.drop_index("ix_source_chunks_source_id", table_name="source_chunks")
    op.drop_table("source_chunks")
