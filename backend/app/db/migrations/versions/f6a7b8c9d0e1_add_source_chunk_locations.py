"""add source chunk locations

Revision ID: f6a7b8c9d0e1
Revises: d3f4a1b8c2e9
Create Date: 2026-06-21 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f6a7b8c9d0e1"
down_revision: str | Sequence[str] | None = "d3f4a1b8c2e9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "source_chunks",
        sa.Column("location_label", sa.String(255), nullable=False, server_default=""),
    )


def downgrade() -> None:
    op.drop_column("source_chunks", "location_label")
