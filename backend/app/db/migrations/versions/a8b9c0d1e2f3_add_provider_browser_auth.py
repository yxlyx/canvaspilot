"""add provider browser authentication

Revision ID: a8b9c0d1e2f3
Revises: f7a8b9c0d1e2
Create Date: 2026-08-01 10:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a8b9c0d1e2f3"
down_revision: str | Sequence[str] | None = "f7a8b9c0d1e2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("provider_settings", "encrypted_api_key", nullable=True)
    op.add_column(
        "provider_settings",
        sa.Column("auth_method", sa.String(30), nullable=False, server_default="api_key"),
    )
    op.add_column("provider_settings", sa.Column("encrypted_access_token", sa.LargeBinary()))
    op.add_column("provider_settings", sa.Column("encrypted_refresh_token", sa.LargeBinary()))
    op.add_column(
        "provider_settings", sa.Column("access_token_expires_at", sa.DateTime(timezone=True))
    )
    op.add_column("provider_settings", sa.Column("provider_account_id", sa.String(255)))
    op.add_column("provider_settings", sa.Column("provider_subject_id", sa.String(255)))
    op.add_column("provider_settings", sa.Column("provider_account_label", sa.String(320)))
    op.add_column("provider_settings", sa.Column("granted_scopes", sa.Text()))
    op.add_column("provider_settings", sa.Column("last_error_code", sa.String(100)))
    op.add_column("provider_settings", sa.Column("last_refreshed_at", sa.DateTime(timezone=True)))
    op.create_table(
        "provider_authorization_sessions",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id",
            sa.UUID(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("provider", sa.String(50), nullable=False),
        sa.Column("auth_method", sa.String(30), nullable=False),
        sa.Column("state_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("encrypted_pkce_verifier", sa.LargeBinary()),
        sa.Column("encryption_key_id", sa.String(100), nullable=False),
        sa.Column("nonce_hash", sa.String(64), nullable=False),
        sa.Column("browser_binding_hash", sa.String(64), nullable=False),
        sa.Column("return_path", sa.String(500), nullable=False),
        sa.Column("status", sa.String(30), nullable=False, server_default="pending"),
        sa.Column("error_code", sa.String(100)),
        sa.Column("error_message", sa.Text()),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True)),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'completed', 'failed', 'expired', 'cancelled')",
            name="ck_provider_auth_sessions_status",
        ),
    )
    op.create_index(
        "ix_provider_auth_sessions_user_created",
        "provider_authorization_sessions",
        ["user_id", "created_at"],
    )
    op.create_index(
        "ix_provider_auth_sessions_expires",
        "provider_authorization_sessions",
        ["expires_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_provider_auth_sessions_expires", table_name="provider_authorization_sessions")
    op.drop_index(
        "ix_provider_auth_sessions_user_created", table_name="provider_authorization_sessions"
    )
    op.drop_table("provider_authorization_sessions")
    op.drop_column("provider_settings", "last_refreshed_at")
    op.drop_column("provider_settings", "last_error_code")
    op.drop_column("provider_settings", "granted_scopes")
    op.drop_column("provider_settings", "provider_account_label")
    op.drop_column("provider_settings", "provider_subject_id")
    op.drop_column("provider_settings", "provider_account_id")
    op.drop_column("provider_settings", "access_token_expires_at")
    op.drop_column("provider_settings", "encrypted_refresh_token")
    op.drop_column("provider_settings", "encrypted_access_token")
    op.drop_column("provider_settings", "auth_method")
    op.execute("DELETE FROM provider_settings WHERE encrypted_api_key IS NULL")
    op.alter_column("provider_settings", "encrypted_api_key", nullable=False)
