import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, TimestampMixin, gen_uuid


class FlashcardDeck(TimestampMixin, Base):
    __tablename__ = "flashcard_decks"
    __table_args__ = (
        Index("ix_flashcard_decks_user_updated_at", "user_id", "updated_at"),
        Index("ix_flashcard_decks_source_ids", "source_ids", postgresql_using="gin"),
        Index("ix_flashcard_decks_topic_tags", "topic_tags", postgresql_using="gin"),
        Index(
            "uq_flashcard_decks_user_fingerprint",
            "user_id",
            "input_fingerprint",
            unique=True,
            postgresql_where=text("input_fingerprint IS NOT NULL AND predecessor_id IS NULL"),
        ),
        CheckConstraint(
            "lifecycle IN ('draft', 'approved', 'retired', 'archived')",
            name="ck_flashcard_decks_lifecycle",
        ),
        CheckConstraint("revision > 0", name="ck_flashcard_decks_revision"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    title: Mapped[str] = mapped_column(String(1000))
    description: Mapped[str] = mapped_column(Text, default="")
    generation_scope: Mapped[str] = mapped_column(String(50))
    source_ids: Mapped[list[uuid.UUID]] = mapped_column(
        ARRAY(UUID(as_uuid=True)),
        default=list,
        server_default=text("'{}'::uuid[]"),
    )
    wiki_page_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("wiki_pages.id", ondelete="SET NULL")
    )
    topic_tags: Mapped[list[str]] = mapped_column(
        ARRAY(String(100)),
        default=list,
        server_default=text("'{}'::character varying[]"),
    )
    card_count: Mapped[int] = mapped_column(Integer, default=0)
    lifecycle: Mapped[str] = mapped_column(String(20), default="draft")
    revision: Mapped[int] = mapped_column(Integer, default=1)
    input_fingerprint: Mapped[str | None] = mapped_column(String(64))
    scope_snapshot: Mapped[dict] = mapped_column(JSONB, default=dict)
    generator_snapshot: Mapped[dict] = mapped_column(JSONB, default=dict)
    enrollment_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("module_enrollments.id", ondelete="SET NULL")
    )
    topic_ids: Mapped[list[uuid.UUID]] = mapped_column(
        ARRAY(UUID(as_uuid=True)), default=list, server_default=text("'{}'::uuid[]")
    )
    predecessor_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("flashcard_decks.id", ondelete="SET NULL")
    )
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    retired_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    approved_snapshot: Mapped[dict | None] = mapped_column(JSONB)

    cards: Mapped[list["Flashcard"]] = relationship(
        back_populates="deck",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="Flashcard.order_index, Flashcard.id",
    )


class Flashcard(TimestampMixin, Base):
    __tablename__ = "flashcards"
    __table_args__ = (
        Index("ix_flashcards_user_deck", "user_id", "deck_id"),
        Index("ix_flashcards_source_id", "source_id"),
        Index("ix_flashcards_source_chunk_id", "source_chunk_id"),
        Index("ix_flashcards_wiki_page_id", "wiki_page_id"),
        Index("ix_flashcards_topic_tag", "user_id", "topic_tag"),
        CheckConstraint("state IN ('active', 'discarded')", name="ck_flashcards_state"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    deck_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("flashcard_decks.id", ondelete="CASCADE"))
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sources.id", ondelete="SET NULL")
    )
    source_chunk_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("source_chunks.id", ondelete="SET NULL")
    )
    wiki_page_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("wiki_pages.id", ondelete="SET NULL")
    )
    order_index: Mapped[int] = mapped_column(Integer)
    card_type: Mapped[str] = mapped_column(String(50))
    question: Mapped[str] = mapped_column(Text)
    answer: Mapped[str] = mapped_column(Text)
    topic_tag: Mapped[str] = mapped_column(String(100), default="general")
    topic_ids: Mapped[list[uuid.UUID]] = mapped_column(
        ARRAY(UUID(as_uuid=True)), default=list, server_default=text("'{}'::uuid[]")
    )
    tags: Mapped[list[str]] = mapped_column(
        ARRAY(String(100)), default=list, server_default=text("'{}'::varchar[]")
    )
    citation_ref: Mapped[str] = mapped_column(String(1000))
    citations: Mapped[list] = mapped_column(JSONB, default=list)
    source_title: Mapped[str] = mapped_column(String(1000), default="")
    location_label: Mapped[str] = mapped_column(String(255), default="")
    state: Mapped[str] = mapped_column(String(16), default="active")
    manual_note: Mapped[bool] = mapped_column(Boolean, default=False)
    approved: Mapped[bool] = mapped_column(Boolean, default=False)

    deck: Mapped[FlashcardDeck] = relationship(back_populates="cards")
    attempts: Mapped[list["FlashcardAttempt"]] = relationship(
        back_populates="card",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class FlashcardRevision(Base):
    __tablename__ = "flashcard_revisions"
    __table_args__ = (
        UniqueConstraint("deck_id", "revision", name="uq_flashcard_revisions_deck_revision"),
        Index("ix_flashcard_revisions_deck_created", "deck_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    deck_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("flashcard_decks.id", ondelete="CASCADE"))
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    revision: Mapped[int] = mapped_column(Integer)
    action: Mapped[str] = mapped_column(String(32))
    before: Mapped[dict] = mapped_column(JSONB)
    after: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")


class FlashcardAttempt(Base):
    __tablename__ = "flashcard_attempts"
    __table_args__ = (
        Index("ix_flashcard_attempts_user_created_at", "user_id", "created_at"),
        Index("ix_flashcard_attempts_card_id", "card_id"),
        Index("ix_flashcard_attempts_deck_id", "deck_id"),
        Index("uq_flashcard_attempts_user_key", "user_id", "idempotency_key", unique=True),
        CheckConstraint("rating IN ('Again', 'Hard', 'Good', 'Easy')", name="ck_attempt_rating"),
        CheckConstraint(
            "(rating = 'Again' AND is_correct = false AND ease = 1) OR "
            "(rating = 'Hard' AND is_correct = true AND ease = 2) OR "
            "(rating = 'Good' AND is_correct = true AND ease = 3) OR "
            "(rating = 'Easy' AND is_correct = true AND ease = 5)",
            name="ck_attempt_rating_semantics",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    deck_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("flashcard_decks.id", ondelete="CASCADE"))
    card_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("flashcards.id", ondelete="CASCADE"))
    answer_text: Mapped[str] = mapped_column(Text, default="")
    rating: Mapped[str] = mapped_column(String(8))
    ease: Mapped[int] = mapped_column(Integer)
    idempotency_key: Mapped[str] = mapped_column(String(128))
    request_hash: Mapped[str] = mapped_column(String(64))
    is_correct: Mapped[bool] = mapped_column(Boolean)
    confidence: Mapped[int | None] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")

    card: Mapped[Flashcard] = relationship(back_populates="attempts")
    evidence: Mapped["LearningEvidence"] = relationship(
        back_populates="attempt",
        cascade="all, delete-orphan",
        lazy="selectin",
        uselist=False,
    )


class LearningEvidence(Base):
    __tablename__ = "learning_evidence"
    __table_args__ = (
        Index("ix_learning_evidence_user_occurred_at", "user_id", "occurred_at"),
        Index("ix_learning_evidence_user_topic", "user_id", "topic_tag"),
        Index("ix_learning_evidence_source_id", "source_id"),
        Index("ix_learning_evidence_flashcard_id", "flashcard_id"),
        Index(
            "uq_learning_evidence_flashcard_attempt",
            "flashcard_attempt_id",
            unique=True,
            postgresql_where=text("flashcard_attempt_id IS NOT NULL"),
        ),
        Index(
            "uq_learning_evidence_marked_question",
            "marked_paper_question_id",
            unique=True,
            postgresql_where=text("marked_paper_question_id IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=gen_uuid)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    evidence_type: Mapped[str] = mapped_column(String(50))
    topic_tag: Mapped[str] = mapped_column(String(100), default="general")
    source_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sources.id", ondelete="SET NULL")
    )
    source_chunk_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("source_chunks.id", ondelete="SET NULL")
    )
    wiki_page_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("wiki_pages.id", ondelete="SET NULL")
    )
    flashcard_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("flashcards.id", ondelete="CASCADE")
    )
    flashcard_attempt_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("flashcard_attempts.id", ondelete="CASCADE")
    )
    marked_paper_question_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("marked_paper_questions.id", ondelete="CASCADE")
    )
    is_correct: Mapped[bool | None] = mapped_column(Boolean)
    confidence: Mapped[int | None] = mapped_column(Integer)
    citation_ref: Mapped[str] = mapped_column(String(1000), default="")
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default="now()")

    attempt: Mapped[FlashcardAttempt] = relationship(back_populates="evidence")
