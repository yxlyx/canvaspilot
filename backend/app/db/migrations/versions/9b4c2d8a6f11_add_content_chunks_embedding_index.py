"""add content chunks embedding index

Revision ID: 9b4c2d8a6f11
Revises: e7f3f509ad1b
Create Date: 2026-05-11 17:05:00.000000

"""

from collections.abc import Sequence

from alembic import op

revision: str = "9b4c2d8a6f11"
down_revision: str | Sequence[str] | None = "e7f3f509ad1b"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        """
        CREATE INDEX ix_content_chunks_embedding ON content_chunks
        USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
        """
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_content_chunks_embedding")
