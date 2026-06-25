"""add flashcards and learning evidence

Revision ID: b7c2d3e4f5a6
Revises: a8c1d2e3f4b5
Create Date: 2026-06-24 00:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "b7c2d3e4f5a6"
down_revision: str | Sequence[str] | None = "a8c1d2e3f4b5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "flashcard_decks",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("title", sa.String(1000), nullable=False),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("generation_scope", sa.String(50), nullable=False),
        sa.Column(
            "source_ids",
            postgresql.ARRAY(sa.UUID()),
            nullable=False,
            server_default=sa.text("'{}'::uuid[]"),
        ),
        sa.Column("wiki_page_id", sa.UUID(), sa.ForeignKey("wiki_pages.id", ondelete="SET NULL")),
        sa.Column(
            "topic_tags",
            postgresql.ARRAY(sa.String(100)),
            nullable=False,
            server_default=sa.text("'{}'::character varying[]"),
        ),
        sa.Column("card_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index(
        "ix_flashcard_decks_user_updated_at", "flashcard_decks", ["user_id", "updated_at"]
    )
    op.create_index(
        "ix_flashcard_decks_source_ids",
        "flashcard_decks",
        ["source_ids"],
        postgresql_using="gin",
    )
    op.create_index(
        "ix_flashcard_decks_topic_tags",
        "flashcard_decks",
        ["topic_tags"],
        postgresql_using="gin",
    )

    op.create_table(
        "flashcards",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "deck_id",
            sa.UUID(),
            sa.ForeignKey("flashcard_decks.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("source_id", sa.UUID(), sa.ForeignKey("sources.id", ondelete="SET NULL")),
        sa.Column(
            "source_chunk_id", sa.UUID(), sa.ForeignKey("source_chunks.id", ondelete="SET NULL")
        ),
        sa.Column("wiki_page_id", sa.UUID(), sa.ForeignKey("wiki_pages.id", ondelete="SET NULL")),
        sa.Column("order_index", sa.Integer(), nullable=False),
        sa.Column("card_type", sa.String(50), nullable=False),
        sa.Column("question", sa.Text(), nullable=False),
        sa.Column("answer", sa.Text(), nullable=False),
        sa.Column("topic_tag", sa.String(100), nullable=False, server_default="general"),
        sa.Column("citation_ref", sa.String(1000), nullable=False),
        sa.Column("source_title", sa.String(1000), nullable=False, server_default=""),
        sa.Column("location_label", sa.String(255), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index("ix_flashcards_user_deck", "flashcards", ["user_id", "deck_id"])
    op.create_index("ix_flashcards_source_id", "flashcards", ["source_id"])
    op.create_index("ix_flashcards_source_chunk_id", "flashcards", ["source_chunk_id"])
    op.create_index("ix_flashcards_wiki_page_id", "flashcards", ["wiki_page_id"])
    op.create_index("ix_flashcards_topic_tag", "flashcards", ["user_id", "topic_tag"])

    op.create_table(
        "flashcard_attempts",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column(
            "deck_id",
            sa.UUID(),
            sa.ForeignKey("flashcard_decks.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "card_id",
            sa.UUID(),
            sa.ForeignKey("flashcards.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("answer_text", sa.Text(), nullable=False, server_default=""),
        sa.Column("is_correct", sa.Boolean(), nullable=False),
        sa.Column("confidence", sa.Integer()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index(
        "ix_flashcard_attempts_user_created_at", "flashcard_attempts", ["user_id", "created_at"]
    )
    op.create_index("ix_flashcard_attempts_card_id", "flashcard_attempts", ["card_id"])
    op.create_index("ix_flashcard_attempts_deck_id", "flashcard_attempts", ["deck_id"])

    op.create_table(
        "learning_evidence",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column(
            "user_id", sa.UUID(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("evidence_type", sa.String(50), nullable=False),
        sa.Column("topic_tag", sa.String(100), nullable=False, server_default="general"),
        sa.Column("source_id", sa.UUID(), sa.ForeignKey("sources.id", ondelete="SET NULL")),
        sa.Column(
            "source_chunk_id", sa.UUID(), sa.ForeignKey("source_chunks.id", ondelete="SET NULL")
        ),
        sa.Column("wiki_page_id", sa.UUID(), sa.ForeignKey("wiki_pages.id", ondelete="SET NULL")),
        sa.Column("flashcard_id", sa.UUID(), sa.ForeignKey("flashcards.id", ondelete="CASCADE")),
        sa.Column(
            "flashcard_attempt_id",
            sa.UUID(),
            sa.ForeignKey("flashcard_attempts.id", ondelete="CASCADE"),
        ),
        sa.Column("is_correct", sa.Boolean()),
        sa.Column("confidence", sa.Integer()),
        sa.Column("citation_ref", sa.String(1000), nullable=False, server_default=""),
        sa.Column("occurred_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    op.create_index(
        "ix_learning_evidence_user_occurred_at", "learning_evidence", ["user_id", "occurred_at"]
    )
    op.create_index(
        "ix_learning_evidence_user_topic", "learning_evidence", ["user_id", "topic_tag"]
    )
    op.create_index("ix_learning_evidence_source_id", "learning_evidence", ["source_id"])
    op.create_index("ix_learning_evidence_flashcard_id", "learning_evidence", ["flashcard_id"])
    op.create_index(
        "uq_learning_evidence_flashcard_attempt",
        "learning_evidence",
        ["flashcard_attempt_id"],
        unique=True,
        postgresql_where=sa.text("flashcard_attempt_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_learning_evidence_flashcard_attempt", table_name="learning_evidence")
    op.drop_index("ix_learning_evidence_flashcard_id", table_name="learning_evidence")
    op.drop_index("ix_learning_evidence_source_id", table_name="learning_evidence")
    op.drop_index("ix_learning_evidence_user_topic", table_name="learning_evidence")
    op.drop_index("ix_learning_evidence_user_occurred_at", table_name="learning_evidence")
    op.drop_table("learning_evidence")
    op.drop_index("ix_flashcard_attempts_deck_id", table_name="flashcard_attempts")
    op.drop_index("ix_flashcard_attempts_card_id", table_name="flashcard_attempts")
    op.drop_index("ix_flashcard_attempts_user_created_at", table_name="flashcard_attempts")
    op.drop_table("flashcard_attempts")
    op.drop_index("ix_flashcards_topic_tag", table_name="flashcards")
    op.drop_index("ix_flashcards_wiki_page_id", table_name="flashcards")
    op.drop_index("ix_flashcards_source_chunk_id", table_name="flashcards")
    op.drop_index("ix_flashcards_source_id", table_name="flashcards")
    op.drop_index("ix_flashcards_user_deck", table_name="flashcards")
    op.drop_table("flashcards")
    op.drop_index("ix_flashcard_decks_topic_tags", table_name="flashcard_decks")
    op.drop_index("ix_flashcard_decks_source_ids", table_name="flashcard_decks")
    op.drop_index("ix_flashcard_decks_user_updated_at", table_name="flashcard_decks")
    op.drop_table("flashcard_decks")
