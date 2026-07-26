"""add provider device authentication

Revision ID: b9c0d1e2f3a4
Revises: a8b9c0d1e2f3
Create Date: 2026-07-26 14:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b9c0d1e2f3a4"
down_revision: str | Sequence[str] | None = "a8b9c0d1e2f3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("provider_authorization_sessions", "state_hash", nullable=True)
    op.alter_column("provider_authorization_sessions", "nonce_hash", nullable=True)
    op.alter_column("provider_authorization_sessions", "browser_binding_hash", nullable=True)
    op.add_column(
        "provider_authorization_sessions", sa.Column("encrypted_device_code", sa.LargeBinary())
    )
    op.add_column("provider_authorization_sessions", sa.Column("verification_uri", sa.String(500)))
    op.add_column(
        "provider_authorization_sessions",
        sa.Column("verification_uri_complete", sa.String(1000)),
    )
    op.add_column("provider_authorization_sessions", sa.Column("user_code", sa.String(100)))
    op.add_column(
        "provider_authorization_sessions", sa.Column("poll_interval_seconds", sa.Integer())
    )
    op.add_column(
        "provider_authorization_sessions",
        sa.Column("next_poll_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    op.execute("DELETE FROM provider_authorization_sessions WHERE auth_method = 'device_code'")
    op.drop_column("provider_authorization_sessions", "next_poll_at")
    op.drop_column("provider_authorization_sessions", "poll_interval_seconds")
    op.drop_column("provider_authorization_sessions", "user_code")
    op.drop_column("provider_authorization_sessions", "verification_uri_complete")
    op.drop_column("provider_authorization_sessions", "verification_uri")
    op.drop_column("provider_authorization_sessions", "encrypted_device_code")
    op.alter_column("provider_authorization_sessions", "browser_binding_hash", nullable=False)
    op.alter_column("provider_authorization_sessions", "nonce_hash", nullable=False)
    op.alter_column("provider_authorization_sessions", "state_hash", nullable=False)
