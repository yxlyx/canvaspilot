import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.exceptions import NotFoundError
from app.models.flashcard import Flashcard, FlashcardAttempt, FlashcardDeck, LearningEvidence
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.models.wiki import WikiPage
from app.schemas.flashcards import FlashcardAttemptCreate, FlashcardGenerateRequest

MIN_CONTEXT_WORDS = 6
MIN_CONTEXT_CHARS = 35


@dataclass
class FlashcardGenerationOutcome:
    deck: FlashcardDeck | None
    generated_count: int
    message: str


@dataclass
class FlashcardCandidate:
    content: str
    citation_ref: str
    source_title: str
    topic_tag: str
    source_id: uuid.UUID | None = None
    source_chunk_id: uuid.UUID | None = None
    wiki_page_id: uuid.UUID | None = None
    location_label: str = ""


def _plain_text(value: str) -> str:
    without_citations = re.sub(r"\[[A-Za-z]+\d+\]", "", value)
    without_links = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", without_citations)
    without_markdown = re.sub(r"[#*_`>\-]+", " ", without_links)
    return re.sub(r"\s+", " ", without_markdown).strip()


def _sentences(value: str) -> list[str]:
    cleaned = _plain_text(value)
    parts = re.split(r"(?<=[.!?])\s+", cleaned)
    sentences: list[str] = []
    for part in parts:
        sentence = part.strip(" .")
        if len(sentence) >= MIN_CONTEXT_CHARS and len(sentence.split()) >= MIN_CONTEXT_WORDS:
            sentences.append(sentence)
    return sentences


def _first_usable_sentence(value: str) -> str | None:
    sentences = _sentences(value)
    if sentences:
        return sentences[0]
    cleaned = _plain_text(value)
    if len(cleaned) >= MIN_CONTEXT_CHARS and len(cleaned.split()) >= MIN_CONTEXT_WORDS:
        return cleaned[:240].rstrip()
    return None


def _topic_from_title(title: str) -> str:
    words = re.findall(r"[a-z0-9]+", title.lower())
    ignored = {"notes", "summary", "source", "chapter", "lecture", "tutorial", "the"}
    for word in words:
        if word not in ignored and len(word) > 2:
            return word[:100]
    return "general"


def _candidate_from_chunk(source: Source, chunk: SourceChunk) -> FlashcardCandidate:
    topic_tag = source.topic_tags[0] if source.topic_tags else _topic_from_title(source.title)
    return FlashcardCandidate(
        content=chunk.content,
        citation_ref=chunk.citation_ref,
        source_title=source.title,
        topic_tag=topic_tag,
        source_id=source.id,
        source_chunk_id=chunk.id,
        location_label=chunk.location_label,
    )


def _wiki_section_for_citation(markdown: str, citation_key: str) -> str:
    marker = f"[^{citation_key}]"
    marker_index = markdown.find(marker)
    if marker_index < 0:
        return ""

    before_marker = markdown[:marker_index]
    section_start = before_marker.rfind("\n## ")
    if section_start < 0:
        section_start = 0
    else:
        section_start += 1
    return markdown[section_start:marker_index].strip()


def _best_wiki_context(page: WikiPage, citation) -> str:
    citation_section = _wiki_section_for_citation(page.markdown, citation.citation_key)
    for value in [citation.snippet, citation_section]:
        if _first_usable_sentence(value) is not None:
            return value
    return citation.snippet or citation_section


def _candidate_from_wiki_citation(page: WikiPage, citation) -> FlashcardCandidate:
    topic_tag = _topic_from_title(page.title)
    return FlashcardCandidate(
        content=_best_wiki_context(page, citation),
        citation_ref=citation.citation_ref,
        source_title=citation.source_title,
        topic_tag=topic_tag,
        source_id=citation.source_id,
        source_chunk_id=citation.source_chunk_id,
        wiki_page_id=page.id,
        location_label=citation.location_label,
    )


def _cloze_question(sentence: str) -> tuple[str, str]:
    words = re.findall(r"[A-Za-z][A-Za-z-]{5,}", sentence)
    keyword = max(words, key=len) if words else sentence.split()[0]
    question = re.sub(rf"\b{re.escape(keyword)}\b", "_____", sentence, count=1)
    return f"Fill in the blank: {question}.", keyword


def _card_fields(
    candidate: FlashcardCandidate, order_index: int
) -> dict[str, str | int | uuid.UUID | None]:
    sentence = _first_usable_sentence(candidate.content)
    if sentence is None:
        raise ValueError("Candidate does not contain enough context")

    card_type_index = order_index % 3
    if card_type_index == 1:
        question = f"What does {candidate.source_title} say about {candidate.topic_tag}?"
        answer = sentence
        card_type = "short_answer"
    elif card_type_index == 2:
        question = f"Explain the key idea from {candidate.citation_ref}."
        answer = sentence
        card_type = "concept_check"
    else:
        question, answer = _cloze_question(sentence)
        card_type = "cloze"

    return {
        "source_id": candidate.source_id,
        "source_chunk_id": candidate.source_chunk_id,
        "wiki_page_id": candidate.wiki_page_id,
        "order_index": order_index,
        "card_type": card_type,
        "question": question,
        "answer": answer,
        "topic_tag": candidate.topic_tag,
        "citation_ref": candidate.citation_ref,
        "source_title": candidate.source_title,
        "location_label": candidate.location_label,
    }


def _deck_title(payload: FlashcardGenerateRequest, candidates: list[FlashcardCandidate]) -> str:
    if payload.deck_title:
        return payload.deck_title
    if payload.topic:
        return f"Flashcards: {payload.topic}"
    if candidates:
        return f"Flashcards: {candidates[0].source_title}"
    return "Flashcards"


def _generation_scope(payload: FlashcardGenerateRequest) -> str:
    if payload.source_ids is not None:
        return "sources"
    if payload.source_chunk_ids is not None:
        return "source_chunks"
    if payload.wiki_page_id is not None:
        return "wiki_page"
    return "topic"


async def _source_candidates(
    user: User,
    db: AsyncSession,
    source_ids: list[uuid.UUID] | None,
    topic: str | None,
) -> tuple[list[FlashcardCandidate], list[uuid.UUID]]:
    statement = (
        select(Source)
        .options(selectinload(Source.chunks))
        .where(Source.user_id == user.id, Source.status == SourceStatus.READY)
        .order_by(Source.updated_at.desc(), Source.title.asc())
    )
    if source_ids is not None:
        statement = statement.where(Source.id.in_(source_ids))
    if topic is not None:
        statement = statement.where(Source.topic_tags.contains([topic]))

    result = await db.execute(statement)
    sources = result.scalars().unique().all()
    if source_ids is not None and len({source.id for source in sources}) != len(source_ids):
        raise NotFoundError("One or more ready sources were not found")

    candidates: list[FlashcardCandidate] = []
    source_id_list: list[uuid.UUID] = []
    for source in sources:
        source_id_list.append(source.id)
        chunks = sorted(source.chunks, key=lambda chunk: chunk.chunk_index)
        for chunk in chunks:
            candidates.append(_candidate_from_chunk(source, chunk))
    return candidates, source_id_list


async def _source_chunk_candidates(
    user: User,
    db: AsyncSession,
    source_chunk_ids: list[uuid.UUID],
) -> tuple[list[FlashcardCandidate], list[uuid.UUID]]:
    result = await db.execute(
        select(SourceChunk, Source)
        .join(Source, SourceChunk.source_id == Source.id)
        .where(
            Source.user_id == user.id,
            Source.status == SourceStatus.READY,
            SourceChunk.id.in_(source_chunk_ids),
        )
    )
    rows = result.all()
    chunks_by_id = {chunk.id: (chunk, source) for chunk, source in rows}
    if len(chunks_by_id) != len(source_chunk_ids):
        raise NotFoundError("One or more ready source chunks were not found")

    candidates: list[FlashcardCandidate] = []
    source_ids: list[uuid.UUID] = []
    seen_sources: set[uuid.UUID] = set()
    for chunk_id in source_chunk_ids:
        chunk, source = chunks_by_id[chunk_id]
        candidates.append(_candidate_from_chunk(source, chunk))
        if source.id not in seen_sources:
            seen_sources.add(source.id)
            source_ids.append(source.id)
    return candidates, source_ids


async def _wiki_candidates(
    user: User,
    db: AsyncSession,
    wiki_page_id: uuid.UUID,
) -> tuple[list[FlashcardCandidate], list[uuid.UUID]]:
    result = await db.execute(
        select(WikiPage)
        .options(selectinload(WikiPage.citations))
        .where(WikiPage.id == wiki_page_id, WikiPage.user_id == user.id)
    )
    page = result.scalar_one_or_none()
    if page is None:
        raise NotFoundError("Wiki page not found")

    citations = sorted(page.citations, key=lambda citation: citation.citation_key)
    candidates = [_candidate_from_wiki_citation(page, citation) for citation in citations]
    return candidates, page.source_ids


async def generate_flashcard_deck(
    user: User,
    payload: FlashcardGenerateRequest,
    db: AsyncSession,
) -> FlashcardGenerationOutcome:
    if payload.source_chunk_ids is not None:
        candidates, source_ids = await _source_chunk_candidates(user, db, payload.source_chunk_ids)
    elif payload.wiki_page_id is not None:
        candidates, source_ids = await _wiki_candidates(user, db, payload.wiki_page_id)
    else:
        candidates, source_ids = await _source_candidates(
            user, db, payload.source_ids, payload.topic
        )

    card_fields: list[dict[str, str | int | uuid.UUID | None]] = []
    seen_answers: set[str] = set()
    for candidate in candidates:
        if len(card_fields) >= payload.limit:
            break
        sentence = _first_usable_sentence(candidate.content)
        if sentence is None:
            continue
        answer_key = sentence.lower()
        if answer_key in seen_answers:
            continue
        seen_answers.add(answer_key)
        card_fields.append(_card_fields(candidate, len(card_fields) + 1))

    if not card_fields:
        return FlashcardGenerationOutcome(
            deck=None,
            generated_count=0,
            message="Not enough cited source context to generate flashcards.",
        )

    topic_tags = sorted({str(fields["topic_tag"]) for fields in card_fields})
    deck = FlashcardDeck(
        user_id=user.id,
        title=_deck_title(payload, candidates),
        description="Cited flashcards generated from workspace source context.",
        generation_scope=_generation_scope(payload),
        source_ids=source_ids,
        wiki_page_id=payload.wiki_page_id,
        topic_tags=topic_tags,
        card_count=len(card_fields),
    )
    db.add(deck)
    await db.flush()

    cards = [
        Flashcard(
            deck_id=deck.id,
            user_id=user.id,
            **fields,
        )
        for fields in card_fields
    ]
    db.add_all(cards)
    await db.commit()
    await db.refresh(deck, attribute_names=["cards"])
    return FlashcardGenerationOutcome(
        deck=deck,
        generated_count=len(cards),
        message="Flashcard deck generated.",
    )


async def list_flashcard_decks(user: User, db: AsyncSession) -> list[FlashcardDeck]:
    result = await db.execute(
        select(FlashcardDeck)
        .options(selectinload(FlashcardDeck.cards))
        .where(FlashcardDeck.user_id == user.id)
        .order_by(FlashcardDeck.updated_at.desc(), FlashcardDeck.title.asc())
    )
    return list(result.scalars().unique().all())


async def get_flashcard_deck(user: User, deck_id: uuid.UUID, db: AsyncSession) -> FlashcardDeck:
    result = await db.execute(
        select(FlashcardDeck)
        .options(selectinload(FlashcardDeck.cards))
        .where(FlashcardDeck.id == deck_id, FlashcardDeck.user_id == user.id)
    )
    deck = result.scalar_one_or_none()
    if deck is None:
        raise NotFoundError("Flashcard deck not found")
    return deck


async def log_flashcard_attempt(
    user: User,
    card_id: uuid.UUID,
    payload: FlashcardAttemptCreate,
    db: AsyncSession,
) -> FlashcardAttempt:
    result = await db.execute(
        select(Flashcard).where(Flashcard.id == card_id, Flashcard.user_id == user.id)
    )
    card = result.scalar_one_or_none()
    if card is None:
        raise NotFoundError("Flashcard not found")

    attempt = FlashcardAttempt(
        user_id=user.id,
        deck_id=card.deck_id,
        card_id=card.id,
        answer_text=payload.answer_text,
        is_correct=payload.is_correct,
        confidence=payload.confidence,
    )
    db.add(attempt)
    await db.flush()

    evidence = LearningEvidence(
        user_id=user.id,
        evidence_type="flashcard_attempt",
        topic_tag=card.topic_tag,
        source_id=card.source_id,
        source_chunk_id=card.source_chunk_id,
        wiki_page_id=card.wiki_page_id,
        flashcard_id=card.id,
        flashcard_attempt_id=attempt.id,
        is_correct=payload.is_correct,
        confidence=payload.confidence,
        citation_ref=card.citation_ref,
        occurred_at=datetime.now(UTC),
    )
    db.add(evidence)
    await db.commit()
    await db.refresh(attempt, attribute_names=["evidence"])
    return attempt


async def list_learning_evidence(
    user: User,
    db: AsyncSession,
    topic_tag: str | None = None,
    limit: int = 50,
) -> list[LearningEvidence]:
    statement = select(LearningEvidence).where(LearningEvidence.user_id == user.id)
    if topic_tag:
        statement = statement.where(LearningEvidence.topic_tag == topic_tag)
    statement = statement.order_by(LearningEvidence.occurred_at.desc()).limit(limit)
    result = await db.execute(statement)
    return list(result.scalars().all())
