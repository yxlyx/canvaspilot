"""add explicit flashcard draft review and study workflow

Revision ID: f7a8b9c0d1e2
Revises: e6f7a8b9c0d1
Create Date: 2026-07-29 12:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "f7a8b9c0d1e2"
down_revision: str | Sequence[str] | None = "e6f7a8b9c0d1"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_index("uq_flashcard_decks_user_fingerprint", table_name="flashcard_decks")
    op.drop_constraint("ck_flashcard_decks_lifecycle", "flashcard_decks", type_="check")
    op.execute("UPDATE flashcard_decks SET lifecycle = 'approved' WHERE lifecycle = 'published'")
    op.create_check_constraint(
        "ck_flashcard_decks_lifecycle",
        "flashcard_decks",
        "lifecycle IN ('draft', 'approved', 'retired', 'archived')",
    )
    op.alter_column("flashcard_decks", "lifecycle", server_default="draft")
    op.add_column(
        "flashcard_decks", sa.Column("revision", sa.Integer(), server_default="1", nullable=False)
    )
    op.add_column(
        "flashcard_decks",
        sa.Column(
            "scope_snapshot",
            postgresql.JSONB(),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
    )
    op.add_column(
        "flashcard_decks",
        sa.Column(
            "generator_snapshot",
            postgresql.JSONB(),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
    )
    op.add_column(
        "flashcard_decks",
        sa.Column(
            "enrollment_id", sa.Uuid(), sa.ForeignKey("module_enrollments.id", ondelete="SET NULL")
        ),
    )
    op.add_column(
        "flashcard_decks",
        sa.Column(
            "topic_ids",
            postgresql.ARRAY(sa.Uuid()),
            server_default=sa.text("'{}'::uuid[]"),
            nullable=False,
        ),
    )
    op.add_column(
        "flashcard_decks",
        sa.Column(
            "predecessor_id", sa.Uuid(), sa.ForeignKey("flashcard_decks.id", ondelete="SET NULL")
        ),
    )
    op.add_column("flashcard_decks", sa.Column("approved_at", sa.DateTime(timezone=True)))
    op.add_column("flashcard_decks", sa.Column("retired_at", sa.DateTime(timezone=True)))
    op.add_column("flashcard_decks", sa.Column("approved_snapshot", postgresql.JSONB()))
    op.create_check_constraint("ck_flashcard_decks_revision", "flashcard_decks", "revision > 0")
    op.create_index(
        "uq_flashcard_decks_user_fingerprint",
        "flashcard_decks",
        ["user_id", "input_fingerprint"],
        unique=True,
        postgresql_where=sa.text("input_fingerprint IS NOT NULL AND predecessor_id IS NULL"),
    )

    op.add_column(
        "flashcards",
        sa.Column(
            "topic_ids",
            postgresql.ARRAY(sa.Uuid()),
            server_default=sa.text("'{}'::uuid[]"),
            nullable=False,
        ),
    )
    op.add_column(
        "flashcards",
        sa.Column(
            "tags",
            postgresql.ARRAY(sa.String(100)),
            server_default=sa.text("'{}'::varchar[]"),
            nullable=False,
        ),
    )
    op.add_column(
        "flashcards",
        sa.Column(
            "citations", postgresql.JSONB(), server_default=sa.text("'[]'::jsonb"), nullable=False
        ),
    )
    op.add_column(
        "flashcards", sa.Column("state", sa.String(16), server_default="active", nullable=False)
    )
    op.add_column(
        "flashcards",
        sa.Column("manual_note", sa.Boolean(), server_default=sa.false(), nullable=False),
    )
    op.add_column(
        "flashcards", sa.Column("approved", sa.Boolean(), server_default=sa.false(), nullable=False)
    )
    op.execute(
        "UPDATE flashcards SET citations = jsonb_build_array(jsonb_build_object('source_id', source_id, 'source_chunk_id', source_chunk_id, 'wiki_page_id', wiki_page_id, 'citation_ref', citation_ref)) WHERE citation_ref <> ''"
    )
    op.execute(
        "UPDATE flashcards SET approved = true WHERE deck_id IN (SELECT id FROM flashcard_decks WHERE lifecycle = 'approved')"
    )
    op.create_check_constraint(
        "ck_flashcards_state", "flashcards", "state IN ('active', 'discarded')"
    )

    op.create_table(
        "flashcard_revisions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "deck_id",
            sa.Uuid(),
            sa.ForeignKey("flashcard_decks.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("action", sa.String(32), nullable=False),
        sa.Column("before", postgresql.JSONB(), nullable=False),
        sa.Column("after", postgresql.JSONB(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.UniqueConstraint("deck_id", "revision", name="uq_flashcard_revisions_deck_revision"),
    )
    op.create_index(
        "ix_flashcard_revisions_deck_created", "flashcard_revisions", ["deck_id", "created_at"]
    )

    op.add_column("flashcard_attempts", sa.Column("rating", sa.String(8)))
    op.add_column("flashcard_attempts", sa.Column("ease", sa.Integer()))
    op.add_column("flashcard_attempts", sa.Column("idempotency_key", sa.String(128)))
    op.add_column("flashcard_attempts", sa.Column("request_hash", sa.String(64)))
    op.execute(
        "UPDATE flashcard_attempts SET rating = CASE WHEN is_correct THEN 'Good' ELSE 'Again' END, ease = CASE WHEN is_correct THEN 3 ELSE 1 END, idempotency_key = 'legacy:' || id::text, request_hash = repeat('0', 64)"
    )
    op.alter_column("flashcard_attempts", "rating", nullable=False)
    op.alter_column("flashcard_attempts", "ease", nullable=False)
    op.alter_column("flashcard_attempts", "idempotency_key", nullable=False)
    op.alter_column("flashcard_attempts", "request_hash", nullable=False)
    op.create_check_constraint(
        "ck_attempt_rating", "flashcard_attempts", "rating IN ('Again', 'Hard', 'Good', 'Easy')"
    )
    op.create_check_constraint(
        "ck_attempt_rating_semantics",
        "flashcard_attempts",
        "(rating = 'Again' AND is_correct = false AND ease = 1) OR "
        "(rating = 'Hard' AND is_correct = true AND ease = 2) OR "
        "(rating = 'Good' AND is_correct = true AND ease = 3) OR "
        "(rating = 'Easy' AND is_correct = true AND ease = 5)",
    )
    op.create_index(
        "uq_flashcard_attempts_user_key",
        "flashcard_attempts",
        ["user_id", "idempotency_key"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("uq_flashcard_attempts_user_key", table_name="flashcard_attempts")
    op.drop_constraint("ck_attempt_rating_semantics", "flashcard_attempts", type_="check")
    op.drop_constraint("ck_attempt_rating", "flashcard_attempts", type_="check")
    op.drop_column("flashcard_attempts", "request_hash")
    op.drop_column("flashcard_attempts", "idempotency_key")
    op.drop_column("flashcard_attempts", "ease")
    op.drop_column("flashcard_attempts", "rating")
    op.drop_table("flashcard_revisions")
    op.drop_constraint("ck_flashcards_state", "flashcards", type_="check")
    for column in ("approved", "manual_note", "state", "citations", "tags", "topic_ids"):
        op.drop_column("flashcards", column)
    op.drop_index("uq_flashcard_decks_user_fingerprint", table_name="flashcard_decks")
    op.drop_constraint("ck_flashcard_decks_revision", "flashcard_decks", type_="check")
    for column in (
        "approved_snapshot",
        "retired_at",
        "approved_at",
        "predecessor_id",
        "topic_ids",
        "enrollment_id",
        "generator_snapshot",
        "scope_snapshot",
        "revision",
    ):
        op.drop_column("flashcard_decks", column)
    op.drop_constraint("ck_flashcard_decks_lifecycle", "flashcard_decks", type_="check")
    op.execute("UPDATE flashcard_decks SET lifecycle = 'published' WHERE lifecycle = 'approved'")
    op.execute("UPDATE flashcard_decks SET lifecycle = 'archived' WHERE lifecycle = 'retired'")
    op.create_check_constraint(
        "ck_flashcard_decks_lifecycle",
        "flashcard_decks",
        "lifecycle IN ('draft', 'published', 'archived')",
    )
    op.alter_column("flashcard_decks", "lifecycle", server_default="published")
    op.create_index(
        "uq_flashcard_decks_user_fingerprint",
        "flashcard_decks",
        ["user_id", "input_fingerprint"],
        unique=True,
        postgresql_where=sa.text("input_fingerprint IS NOT NULL"),
    )
