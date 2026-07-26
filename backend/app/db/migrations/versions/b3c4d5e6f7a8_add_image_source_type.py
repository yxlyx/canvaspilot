"""add image source type

Revision ID: b3c4d5e6f7a8
Revises: a2b3c4d5e6f7
Create Date: 2026-07-25 17:00:00.000000
"""

from collections.abc import Sequence

from alembic import op

revision: str = "b3c4d5e6f7a8"
down_revision: str | Sequence[str] | None = "a2b3c4d5e6f7"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("ALTER TYPE librarysourcetype ADD VALUE IF NOT EXISTS 'image'")


def downgrade() -> None:
    op.execute("ALTER TABLE sources ALTER COLUMN source_type TYPE varchar USING source_type::text")
    op.execute("UPDATE sources SET source_type = 'plain_text' WHERE source_type = 'image'")
    op.execute("DROP TYPE librarysourcetype")
    op.execute(
        "CREATE TYPE librarysourcetype AS ENUM "
        "('markdown', 'plain_text', 'pdf', 'link', 'repository')"
    )
    op.execute(
        "ALTER TABLE sources ALTER COLUMN source_type TYPE librarysourcetype "
        "USING source_type::librarysourcetype"
    )
