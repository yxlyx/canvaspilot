"""add provider runtime selection

Revision ID: a2b3c4d5e6f7
Revises: f1a2b3c4d5e6
Create Date: 2026-07-25 15:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a2b3c4d5e6f7"
down_revision: str | Sequence[str] | None = "f1a2b3c4d5e6"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "provider_settings",
        sa.Column(
            "active_for_generation",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    op.add_column("provider_settings", sa.Column("last_error", sa.Text()))
    op.create_index(
        "uq_provider_settings_active_generation",
        "provider_settings",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text("active_for_generation"),
    )


def downgrade() -> None:
    op.drop_index(
        "uq_provider_settings_active_generation",
        table_name="provider_settings",
    )
    op.drop_column("provider_settings", "last_error")
    op.drop_column("provider_settings", "active_for_generation")
