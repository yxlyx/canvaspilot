"""add password auth

Revision ID: 7a9c2f1e4b6d
Revises: 9b4c2d8a6f11
Create Date: 2026-05-13 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7a9c2f1e4b6d"
down_revision: str | Sequence[str] | None = "9b4c2d8a6f11"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("password_hash", sa.String(512), nullable=True))
    op.alter_column("users", "canvas_user_id", existing_type=sa.Integer(), nullable=True)
    op.alter_column("users", "encrypted_access_token", existing_type=sa.String(1024), nullable=True)
    op.alter_column(
        "users", "encrypted_refresh_token", existing_type=sa.String(1024), nullable=True
    )
    op.create_index("ix_users_email", "users", ["email"], unique=True)


def downgrade() -> None:
    op.drop_index("ix_users_email", table_name="users")
    op.alter_column(
        "users", "encrypted_refresh_token", existing_type=sa.String(1024), nullable=False
    )
    op.alter_column(
        "users", "encrypted_access_token", existing_type=sa.String(1024), nullable=False
    )
    op.alter_column("users", "canvas_user_id", existing_type=sa.Integer(), nullable=False)
    op.drop_column("users", "password_hash")
