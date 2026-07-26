import hashlib
import json
import re
import uuid
from dataclasses import dataclass, replace
from datetime import UTC, datetime

from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.exceptions import NotFoundError, WikiBaseError
from app.models.curriculum import CurriculumTopic, ModuleEnrollment, TopicSourceAssociation
from app.models.flashcard import (
    Flashcard,
    FlashcardAttempt,
    FlashcardDeck,
    FlashcardRevision,
    LearningEvidence,
)
from app.models.processing import SourceVersion
from app.models.source import Source, SourceStatus
from app.models.source_chunk import (
    SourceChunk,
    active_source_chunk_predicate,
    is_active_source_chunk,
)
from app.models.user import User
from app.models.wiki import WikiCitation, WikiPage
from app.schemas.flashcards import (
    DraftCardAdd,
    DraftCardUpdate,
    FlashcardAttemptCreate,
    FlashcardGenerateRequest,
    GeneratedFlashcardBatch,
    GeneratedFlashcardWording,
)
from app.services.llm import generate_json_text
from app.services.providers import GenerationProvider, resolve_generation_provider

MIN_CONTEXT_WORDS = 6
MIN_CONTEXT_CHARS = 35
FLASHCARD_PROMPT_VERSION = "2"
FLASHCARD_SCHEMA_VERSION = "2"
FLASHCARD_SYSTEM_PROMPT = """Create university study flashcards from the supplied evidence.
Use only the evidence in the request.
Return one focused card for each useful evidence item.
Test a specific idea, relationship, distinction, procedure, constraint, or complexity.
Avoid generic prompts such as 'What is the key idea?'.
Do not ask about facts absent from the evidence.
Answers must be concise, self-contained verbatim spans copied from the matching evidence.
Support quotes must be exact evidence spans that contain the answer.
Do not mention evidence keys, source titles, citations, pages, or passages in questions or answers.
Return only JSON matching this shape:
{"cards":[{"evidence_key":"E1","question":"...","answer":"...","support_quote":"...","card_type":"definition|concept_check|comparison|procedure|complexity|misconception"}]}
Each evidence key may appear at most once. Do not combine evidence items."""


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
    topic_id: uuid.UUID | None = None
    topic_is_authoritative: bool = False
    evidence_excerpt: str = ""


def _generator_identity(provider: GenerationProvider) -> dict[str, object]:
    if provider.transport == "chat_completions":
        parameters: dict[str, object] = {"max_tokens": 4096, "temperature": 0.2}
    elif provider.transport == "responses":
        parameters = {"max_output_tokens": 4096}
    else:
        parameters = {"output_limit": "local_connector_policy"}
    return {
        "kind": "provider_structured",
        "version": FLASHCARD_PROMPT_VERSION,
        "provider": provider.provider,
        "model": provider.model,
        "transport": provider.transport,
        "auth_method": provider.auth_method,
        "endpoint_fingerprint": hashlib.sha256(provider.endpoint.encode()).hexdigest()[:16],
        "config": {
            "schema_version": FLASHCARD_SCHEMA_VERSION,
            "parameters": parameters,
            "evidence_policy": "one_card_per_evidence_unit",
        },
    }


def _plain_text(value: str) -> str:
    without_citations = re.sub(r"\[[A-Za-z]+\d+\]", "", value)
    without_links = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", without_citations)
    without_markdown = re.sub(r"[#*_`>]+", " ", without_links)
    return re.sub(r"\s+", " ", without_markdown).strip()


_SOURCE_METADATA_TERMS = (
    "academic year",
    "course code",
    "document title",
    "module code",
    "prepared by",
    "source header",
    "cover page",
    "which institution",
    "which university",
)


def _looks_like_source_metadata(value: str) -> bool:
    lowered = _plain_text(value).casefold()
    explicit = sum(term in lowered for term in _SOURCE_METADATA_TERMS)
    header_fields = sum(
        term in lowered
        for term in ("institution", "department", "faculty", "semester", "copyright")
    )
    asks_for_header_fact = ("what" in lowered or "which" in lowered) and header_fields > 0
    return explicit > 0 or header_fields >= 2 or asks_for_header_fact


def _generated_wording_is_low_signal(wording: GeneratedFlashcardWording) -> bool:
    return _looks_like_source_metadata(wording.question) or len(wording.answer.split()) > 80


def _sentences(value: str) -> list[str]:
    cleaned = _plain_text(value)
    parts = re.split(r"(?<=[.!?])\s+", cleaned)
    sentences: list[str] = []
    for part in parts:
        sentence = part.strip(" .")
        if len(sentence) >= MIN_CONTEXT_CHARS and len(sentence.split()) >= MIN_CONTEXT_WORDS:
            sentences.append(sentence)
    return sentences


def _sentence_score(sentence: str) -> tuple[int, int]:
    lower = sentence.lower()
    signals = [
        " is ",
        " are ",
        " refers to ",
        " means ",
        " because ",
        " requires ",
        " compared ",
        " difference ",
        "complexity",
        "o(",
    ]
    score = sum(2 for signal in signals if signal in lower)
    if 8 <= len(sentence.split()) <= 36:
        score += 3
    if sentence.endswith(":") or sentence.lower().startswith(("chapter ", "lecture ")):
        score -= 3
    return score, -len(sentence)


def _first_usable_sentence(value: str) -> str | None:
    sentences = _sentences(value)
    if sentences:
        return max(sentences, key=_sentence_score)
    cleaned = _plain_text(value)
    if len(cleaned) >= MIN_CONTEXT_CHARS and len(cleaned.split()) >= MIN_CONTEXT_WORDS:
        return cleaned[:320].rstrip()
    return None


def _topic_from_title(title: str) -> str:
    words = re.findall(r"[a-z0-9]+", title.lower())
    ignored = {"notes", "summary", "source", "chapter", "lecture", "tutorial", "the"}
    for word in words:
        if word not in ignored and len(word) > 2:
            return word[:100]
    return "general"


def _candidate_from_chunk(
    source: Source, chunk: SourceChunk, topic: str | None = None
) -> FlashcardCandidate:
    if topic is not None:
        topic_tag = topic
    else:
        topic_tag = source.topic_tags[0] if source.topic_tags else _topic_from_title(source.title)
    return FlashcardCandidate(
        content=chunk.content,
        citation_ref=chunk.citation_ref,
        source_title=source.title,
        topic_tag=topic_tag,
        source_id=source.id,
        source_chunk_id=chunk.id,
        location_label=chunk.location_label,
        topic_is_authoritative=topic is not None,
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


def _concept_label(candidate: FlashcardCandidate, sentence: str) -> str:
    topic = _plain_text(candidate.topic_tag).strip(" .:-")
    if (
        candidate.topic_is_authoritative
        and topic
        and topic.lower()
        not in {
            "general",
            "source",
            "notes",
        }
    ):
        return topic[:120]
    procedure = re.match(
        r"(?:to\s+)?((?:insert|delete|remove|update)\w*\s+[^,.;]+)",
        sentence,
        flags=re.IGNORECASE,
    )
    if procedure:
        return procedure.group(1).strip()[:120]
    subject = re.split(
        r"\s+(?:is|are|means|refers to|requires?|uses?|has|describes?|measures?|"
        r"represents?|preserves?|stores?|must|cannot)\s+",
        sentence,
        maxsplit=1,
        flags=re.IGNORECASE,
    )[0]
    if subject.lower().startswith(("unlike ", "compared ")) and "," in subject:
        subject = subject.split(",", 1)[1]
    subject = re.sub(r"^(?:the|a|an)\s+", "", subject, flags=re.IGNORECASE).strip(" .:-")
    words = subject.split()
    return " ".join(words[-8:])[:120] if words else "this concept"


def _typed_question(concept: str, sentence: str) -> tuple[str, str]:
    lower = sentence.lower()
    if "o(" in lower or "complexity" in lower:
        return f"What complexity does the evidence give for {concept}?", "complexity"
    if any(term in lower for term in ("compared", "difference", "whereas", "unlike")):
        return f"What comparison does the evidence make about {concept}?", "comparison"
    if any(term in lower for term in ("must", "cannot", "never", "instead")):
        return f"What constraint does the evidence state about {concept}?", "misconception"
    if any(term in lower for term in ("insert", "delete", "remove", "update", "steps")):
        return f"What procedure does the evidence describe for {concept}?", "procedure"
    if re.search(r"\b(?:is|are|means|refers to)\b", lower):
        return f"How is {concept} defined or described?", "definition"
    return f"What is the key idea behind {concept}?", "concept_check"


def _card_fields(
    candidate: FlashcardCandidate,
    order_index: int,
    wording: GeneratedFlashcardWording | None = None,
) -> dict[str, object]:
    sentence = _first_usable_sentence(candidate.content)
    if sentence is None:
        raise ValueError("Candidate does not contain enough context")

    concept = _concept_label(candidate, sentence)
    if wording is None:
        question, card_type = _typed_question(concept, sentence)
        answer = sentence[:360].rstrip()
    else:
        question = wording.question
        answer = wording.answer
        card_type = wording.card_type
    excerpt = (
        wording.support_quote
        if wording is not None
        else candidate.evidence_excerpt or candidate.content
    )

    return {
        "source_id": candidate.source_id,
        "source_chunk_id": candidate.source_chunk_id,
        "wiki_page_id": candidate.wiki_page_id,
        "order_index": order_index,
        "card_type": card_type,
        "question": question,
        "answer": answer,
        "topic_tag": concept,
        "topic_ids": [candidate.topic_id] if candidate.topic_id else [],
        "citation_ref": candidate.citation_ref,
        "citations": [
            {
                "source_id": str(candidate.source_id) if candidate.source_id else None,
                "source_chunk_id": (
                    str(candidate.source_chunk_id) if candidate.source_chunk_id else None
                ),
                "wiki_page_id": str(candidate.wiki_page_id) if candidate.wiki_page_id else None,
                "citation_ref": candidate.citation_ref,
                "topic_id": str(candidate.topic_id) if candidate.topic_id else None,
                "excerpt": excerpt,
            }
        ],
        "source_title": candidate.source_title,
        "location_label": candidate.location_label,
    }


def _generation_candidates(
    candidates: list[FlashcardCandidate], limit: int
) -> list[FlashcardCandidate]:
    selected: list[FlashcardCandidate] = []
    seen: set[tuple[uuid.UUID | None, uuid.UUID | None, str]] = set()
    for candidate in candidates:
        if len(selected) >= limit:
            break
        evidence = _plain_text(candidate.evidence_excerpt or candidate.content)
        if _first_usable_sentence(evidence) is None:
            continue
        if _looks_like_source_metadata(evidence):
            continue
        key = (candidate.topic_id, candidate.source_chunk_id, evidence.lower())
        if key in seen:
            continue
        seen.add(key)
        selected.append(replace(candidate, content=evidence[:1800]))
    return selected


async def _generate_card_fields(
    user: User,
    db: AsyncSession,
    provider: GenerationProvider,
    candidates: list[FlashcardCandidate],
) -> tuple[GenerationProvider, list[dict[str, object]]]:
    evidence_items = [
        {
            "evidence_key": f"E{index}",
            "topic": _concept_label(
                candidate,
                _first_usable_sentence(candidate.content) or candidate.content,
            ),
            "evidence": candidate.content,
        }
        for index, candidate in enumerate(candidates, start=1)
    ]
    provider, raw = await generate_json_text(
        FLASHCARD_SYSTEM_PROMPT,
        json.dumps({"evidence_items": evidence_items}, ensure_ascii=False),
        user,
        db,
        provider,
        GeneratedFlashcardBatch.model_json_schema(),
    )
    cleaned = raw.strip()
    if cleaned.startswith("```") and cleaned.endswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.IGNORECASE)
    try:
        batch = GeneratedFlashcardBatch.model_validate_json(cleaned)
    except ValidationError as exc:
        raise WikiBaseError(
            502,
            "provider_invalid_response",
            "The answer provider returned flashcards in an invalid format",
        ) from exc

    expected = {f"E{index}" for index in range(1, len(candidates) + 1)}
    returned = {card.evidence_key for card in batch.cards}
    if not returned.issubset(expected):
        raise WikiBaseError(
            502,
            "provider_invalid_response",
            "The answer provider referenced evidence outside this draft",
        )
    by_key = {card.evidence_key: card for card in batch.cards}
    for index, candidate in enumerate(candidates, start=1):
        wording = by_key.get(f"E{index}")
        if wording is None:
            continue
        evidence = re.sub(r"\s+", " ", candidate.content).strip().casefold()
        support = re.sub(r"\s+", " ", wording.support_quote).strip().casefold()
        answer = re.sub(r"\s+", " ", wording.answer).strip().casefold()
        question = wording.question.casefold()
        if _generated_wording_is_low_signal(wording):
            raise WikiBaseError(
                502,
                "provider_invalid_response",
                "The answer provider returned a low-signal metadata flashcard",
            )
        if support not in evidence or answer not in support:
            raise WikiBaseError(
                502,
                "provider_invalid_response",
                "The answer provider returned a flashcard without exact evidence support",
            )
        if (
            candidate.source_title.casefold() in question
            or candidate.citation_ref.casefold() in question
        ):
            raise WikiBaseError(
                502,
                "provider_invalid_response",
                "The answer provider exposed citation metadata in a flashcard question",
            )
    fields = [
        _card_fields(candidate, order_index, by_key[f"E{candidate_index}"])
        for order_index, (candidate_index, candidate) in enumerate(
            (
                (index, candidate)
                for index, candidate in enumerate(candidates, start=1)
                if f"E{index}" in by_key
            ),
            start=1,
        )
    ]
    return provider, fields


def _deck_title(payload: FlashcardGenerateRequest, candidates: list[FlashcardCandidate]) -> str:
    if payload.deck_title:
        return payload.deck_title
    if payload.topic:
        return f"Flashcards: {payload.topic}"
    if candidates:
        return f"Flashcards: {candidates[0].source_title}"
    return "Flashcards"


def _generation_scope(payload: FlashcardGenerateRequest) -> str:
    if payload.enrollment_id is not None:
        return "enrollment"
    if payload.topic_ids is not None:
        return "topics"
    if payload.source_ids is not None:
        return "sources"
    if payload.source_chunk_ids is not None:
        return "source_chunks"
    if payload.wiki_page_id is not None:
        return "wiki_page"
    return "topic"


async def _lock_ready_sources(
    user: User, db: AsyncSession, source_ids: list[uuid.UUID]
) -> list[Source]:
    if not source_ids:
        return []
    sources = list(
        (
            await db.execute(
                select(Source)
                .where(
                    Source.id.in_(source_ids),
                    Source.user_id == user.id,
                    Source.status == SourceStatus.READY,
                )
                .order_by(Source.id)
                .with_for_update()
            )
        ).scalars()
    )
    if len(sources) != len(set(source_ids)):
        raise NotFoundError("One or more ready sources were not found")
    return sources


async def _source_candidates(
    user: User,
    db: AsyncSession,
    source_ids: list[uuid.UUID] | None,
    topic: str | None,
) -> tuple[list[FlashcardCandidate], list[uuid.UUID]]:
    source_scope = select(Source.id).where(
        Source.user_id == user.id, Source.status == SourceStatus.READY
    )
    if source_ids is not None:
        source_scope = source_scope.where(Source.id.in_(source_ids))
    if topic is not None:
        source_scope = source_scope.where(Source.topic_tags.contains([topic]))
    scoped_ids = list((await db.execute(source_scope)).scalars())
    if source_ids is not None and len(set(scoped_ids)) != len(source_ids):
        raise NotFoundError("One or more ready sources were not found")
    await _lock_ready_sources(user, db, scoped_ids)

    result = await db.execute(
        select(Source)
        .options(
            selectinload(
                Source.chunks.and_(
                    SourceChunk.source.has(active_source_chunk_predicate(SourceChunk, Source))
                )
            )
        )
        .where(Source.id.in_(scoped_ids))
        .order_by(Source.updated_at.desc(), Source.title.asc(), Source.id)
    )
    sources = result.scalars().unique().all()

    candidates: list[FlashcardCandidate] = []
    source_id_list: list[uuid.UUID] = []
    for source in sources:
        source_id_list.append(source.id)
        chunks = sorted(
            (chunk for chunk in source.chunks if is_active_source_chunk(chunk, source)),
            key=lambda chunk: chunk.chunk_index,
        )
        for chunk in chunks:
            candidates.append(_candidate_from_chunk(source, chunk, topic))
    return candidates, source_id_list


async def _topic_evidence_candidates(
    user: User,
    db: AsyncSession,
    enrollment_id: uuid.UUID,
    topic_ids: list[uuid.UUID],
) -> tuple[list[FlashcardCandidate], list[uuid.UUID]]:
    rows = (
        await db.execute(
            select(TopicSourceAssociation, CurriculumTopic)
            .join(CurriculumTopic, CurriculumTopic.id == TopicSourceAssociation.topic_id)
            .where(
                TopicSourceAssociation.enrollment_id == enrollment_id,
                TopicSourceAssociation.topic_id.in_(topic_ids),
                TopicSourceAssociation.status == "confirmed",
                TopicSourceAssociation.stale.is_(False),
                CurriculumTopic.archived.is_(False),
            )
            .order_by(CurriculumTopic.position, TopicSourceAssociation.source_id)
        )
    ).all()
    evidence_units: list[tuple[CurriculumTopic, uuid.UUID, uuid.UUID, dict]] = []
    for association, topic in rows:
        for evidence in association.evidence:
            try:
                chunk_id = uuid.UUID(str(evidence.get("chunk_id")))
            except (TypeError, ValueError, AttributeError):
                continue
            evidence_units.append((topic, association.source_id, chunk_id, evidence))

    if not evidence_units:
        return [], []
    chunk_ids = list(dict.fromkeys(unit[2] for unit in evidence_units))
    base_candidates, source_ids = await _source_chunk_candidates(user, db, chunk_ids)
    candidates_by_chunk = {
        candidate.source_chunk_id: candidate
        for candidate in base_candidates
        if candidate.source_chunk_id is not None
    }
    candidates: list[FlashcardCandidate] = []
    for topic, association_source_id, chunk_id, evidence in evidence_units:
        candidate = candidates_by_chunk.get(chunk_id)
        if candidate is None or candidate.source_id != association_source_id:
            continue
        evidence_excerpt = str(evidence.get("excerpt") or "").strip()
        if _first_usable_sentence(evidence_excerpt) is None:
            continue
        candidates.append(
            replace(
                candidate,
                content=evidence_excerpt,
                topic_id=topic.id,
                topic_tag=topic.title,
                topic_is_authoritative=True,
                evidence_excerpt=evidence_excerpt,
            )
        )
    return candidates, list(dict.fromkeys(candidate.source_id for candidate in candidates))


async def _source_chunk_candidates(
    user: User,
    db: AsyncSession,
    source_chunk_ids: list[uuid.UUID],
) -> tuple[list[FlashcardCandidate], list[uuid.UUID]]:
    scoped_source_ids = list(
        (
            await db.execute(
                select(SourceChunk.source_id).where(SourceChunk.id.in_(source_chunk_ids)).distinct()
            )
        ).scalars()
    )
    await _lock_ready_sources(user, db, scoped_source_ids)
    result = await db.execute(
        select(SourceChunk, Source)
        .join(Source, SourceChunk.source_id == Source.id)
        .where(
            Source.user_id == user.id,
            Source.status == SourceStatus.READY,
            SourceChunk.id.in_(source_chunk_ids),
            active_source_chunk_predicate(SourceChunk, Source),
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
    page_id = await db.scalar(
        select(WikiPage.id).where(
            WikiPage.id == wiki_page_id,
            WikiPage.user_id == user.id,
            WikiPage.is_current.is_(True),
        )
    )
    if page_id is None:
        raise NotFoundError("Wiki page not found")
    source_ids = list(
        (
            await db.execute(
                select(WikiCitation.source_id)
                .where(WikiCitation.page_id == page_id)
                .distinct()
                .order_by(WikiCitation.source_id)
            )
        ).scalars()
    )
    try:
        await _lock_ready_sources(user, db, source_ids)
    except NotFoundError as exc:
        raise WikiBaseError(
            409, "citation_not_current", "Wiki citation source is not current"
        ) from exc
    page = await db.scalar(
        select(WikiPage)
        .where(
            WikiPage.id == page_id,
            WikiPage.user_id == user.id,
            WikiPage.is_current.is_(True),
        )
        .with_for_update()
    )
    if page is None:
        raise WikiBaseError(409, "citation_not_current", "Wiki page is not current")
    await db.refresh(page, attribute_names=["citations"])
    citations = sorted(page.citations, key=lambda citation: (citation.citation_key, citation.id))
    if set(source_ids) != {citation.source_id for citation in citations}:
        raise WikiBaseError(409, "citation_not_current", "Wiki citations changed during generation")
    for citation in citations:
        if citation.source_chunk_id is None:
            raise WikiBaseError(409, "citation_not_current", "Wiki citation chunk is not current")
        chunk = await db.scalar(
            select(SourceChunk)
            .join(Source, SourceChunk.source_id == Source.id)
            .where(
                SourceChunk.id == citation.source_chunk_id,
                SourceChunk.source_id == citation.source_id,
                active_source_chunk_predicate(SourceChunk, Source),
            )
        )
        if chunk is None:
            raise WikiBaseError(409, "citation_not_current", "Wiki citation chunk is not current")
    candidates = [_candidate_from_wiki_citation(page, citation) for citation in citations]
    return candidates, source_ids


async def _canonical_scope(
    user: User, payload: FlashcardGenerateRequest, db: AsyncSession
) -> tuple[list[uuid.UUID], uuid.UUID | None]:
    enrollment_id = payload.enrollment_id
    topic_ids = sorted(payload.topic_ids or [], key=str)
    if enrollment_id is not None:
        enrollment = await db.scalar(
            select(ModuleEnrollment).where(
                ModuleEnrollment.id == enrollment_id,
                ModuleEnrollment.user_id == user.id,
                ModuleEnrollment.archived.is_(False),
            )
        )
        if enrollment is None:
            raise NotFoundError("Enrollment not found")
    if topic_ids:
        topics = list(
            (
                await db.execute(
                    select(CurriculumTopic)
                    .join(ModuleEnrollment, CurriculumTopic.enrollment_id == ModuleEnrollment.id)
                    .where(
                        CurriculumTopic.id.in_(topic_ids),
                        CurriculumTopic.state == "canonical",
                        CurriculumTopic.archived.is_(False),
                        ModuleEnrollment.user_id == user.id,
                        ModuleEnrollment.archived.is_(False),
                    )
                )
            ).scalars()
        )
        if len({topic.id for topic in topics}) != len(topic_ids):
            raise NotFoundError("One or more canonical topics were not found")
        enrollment_ids = {topic.enrollment_id for topic in topics}
        if len(enrollment_ids) != 1:
            raise WikiBaseError(422, "mixed_scope", "Topics must belong to one enrollment")
        enrollment_id = enrollment_ids.pop()
    return topic_ids, enrollment_id


async def _scope_snapshot(
    user: User,
    payload: FlashcardGenerateRequest,
    candidates: list[FlashcardCandidate],
    source_ids: list[uuid.UUID],
    topic_ids: list[uuid.UUID],
    enrollment_id: uuid.UUID | None,
    db: AsyncSession,
    generation_policy: dict | None,
) -> dict:
    try:
        locked_sources = await _lock_ready_sources(user, db, source_ids)
    except NotFoundError as exc:
        raise WikiBaseError(409, "source_not_current", "Every source must be current") from exc
    sources_by_id = {source.id: source for source in locked_sources}
    sources = [sources_by_id[source_id] for source_id in source_ids]
    versions = {
        version.id: version
        for version in (
            (
                await db.execute(
                    select(SourceVersion).where(
                        SourceVersion.id.in_(
                            [
                                source.current_version_id
                                for source in sources
                                if source.current_version_id
                            ]
                        ),
                        SourceVersion.status == "ready",
                    )
                )
            )
            .scalars()
            .all()
        )
    }
    legacy_source_fingerprints = {
        source.id: _hash_snapshot(
            {
                "source_id": str(source.id),
                "title": source.title,
                "chunks": [
                    {
                        "id": str(candidate.source_chunk_id),
                        "content": hashlib.sha256(candidate.content.encode()).hexdigest(),
                        "citation_ref": candidate.citation_ref,
                        "location_label": candidate.location_label,
                    }
                    for candidate in candidates
                    if candidate.source_id == source.id
                ],
            }
        )
        for source in sources
        if source.current_version_id is None
    }
    provenance = []
    for candidate in candidates:
        if candidate.source_id is None:
            continue
        source = next(source for source in sources if source.id == candidate.source_id)
        version = versions.get(source.current_version_id)
        if source.current_version_id is not None and version is None:
            raise WikiBaseError(409, "source_not_current", "Every source must be current")
        content_fingerprint = hashlib.sha256(candidate.content.encode()).hexdigest()
        provenance.append(
            {
                "source_id": str(source.id),
                "source_version_id": str(version.id) if version else None,
                "source_fingerprint": (
                    version.fingerprint if version else legacy_source_fingerprints[source.id]
                ),
                "source_chunk_id": (
                    str(candidate.source_chunk_id) if candidate.source_chunk_id else None
                ),
                "wiki_page_id": str(candidate.wiki_page_id) if candidate.wiki_page_id else None,
                "chunk_fingerprint": content_fingerprint,
                "citation_ref": candidate.citation_ref,
                "source_title": candidate.source_title,
                "location_label": candidate.location_label,
                "topic_id": str(candidate.topic_id) if candidate.topic_id else None,
                "topic_title": candidate.topic_tag if candidate.topic_id else None,
                "evidence_excerpt": candidate.evidence_excerpt or candidate.content,
                "evidence_fingerprint": hashlib.sha256(
                    (candidate.evidence_excerpt or candidate.content).encode()
                ).hexdigest(),
            }
        )
    return {
        "kind": _generation_scope(payload),
        "enrollment_id": str(enrollment_id) if enrollment_id else None,
        "topic_ids": [str(value) for value in topic_ids],
        "source_ids": [str(value) for value in source_ids],
        "ordered_provenance": provenance,
        "source_chunk_ids": [str(value) for value in (payload.source_chunk_ids or [])],
        "wiki_page_id": str(payload.wiki_page_id) if payload.wiki_page_id else None,
        "legacy_topic": payload.topic,
        "deck_title": _deck_title(payload, candidates),
        "policy": {"limit": payload.limit, **(generation_policy or {})},
    }


def _hash_snapshot(value: dict) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


async def generate_flashcard_deck(
    user: User,
    payload: FlashcardGenerateRequest,
    db: AsyncSession,
    *,
    generation_policy: dict | None = None,
    commit: bool = True,
    client_host: str = "127.0.0.1",
) -> FlashcardGenerationOutcome:
    topic_ids, enrollment_id = await _canonical_scope(user, payload, db)
    if payload.source_chunk_ids is not None:
        candidates, source_ids = await _source_chunk_candidates(user, db, payload.source_chunk_ids)
    elif payload.wiki_page_id is not None:
        candidates, source_ids = await _wiki_candidates(user, db, payload.wiki_page_id)
    elif enrollment_id is not None:
        if topic_ids:
            candidates, source_ids = await _topic_evidence_candidates(
                user, db, enrollment_id, topic_ids
            )
        else:
            scoped_source_ids = list(
                (
                    await db.execute(
                        select(Source.id).where(
                            Source.user_id == user.id,
                            Source.enrollment_id == enrollment_id,
                        )
                    )
                ).scalars()
            )
            candidates, source_ids = await _source_candidates(user, db, scoped_source_ids, None)
    else:
        candidates, source_ids = await _source_candidates(
            user, db, payload.source_ids, payload.topic
        )

    candidates = _generation_candidates(candidates, payload.limit)
    if not candidates:
        return FlashcardGenerationOutcome(
            deck=None,
            generated_count=0,
            message="Not enough cited source context to generate flashcards.",
        )

    provider = await resolve_generation_provider(user, db, client_host=client_host)
    generator_identity = _generator_identity(provider)
    scope_snapshot = await _scope_snapshot(
        user,
        payload,
        candidates,
        source_ids,
        topic_ids,
        enrollment_id,
        db,
        generation_policy,
    )
    base_fingerprint = _hash_snapshot({"scope": scope_snapshot, "generator": generator_identity})
    await db.execute(
        select(
            func.pg_advisory_xact_lock(
                func.hashtextextended(f"flashcards:{user.id}:{base_fingerprint}", 0)
            )
        )
    )
    lineage = list(
        (
            await db.execute(
                select(FlashcardDeck)
                .where(
                    FlashcardDeck.user_id == user.id,
                    FlashcardDeck.scope_snapshot["base_fingerprint"].as_string()
                    == base_fingerprint,
                )
                .order_by(FlashcardDeck.created_at.desc(), FlashcardDeck.id)
            )
        ).scalars()
    )
    existing = (
        lineage[0]
        if lineage
        else await db.scalar(
            select(FlashcardDeck).where(
                FlashcardDeck.user_id == user.id,
                FlashcardDeck.input_fingerprint == base_fingerprint,
                FlashcardDeck.predecessor_id.is_(None),
            )
        )
    )
    if existing is not None and not payload.regenerate:
        root = next((deck for deck in lineage if deck.predecessor_id is None), existing)
        await db.refresh(root, attribute_names=["cards"])
        return FlashcardGenerationOutcome(root, root.card_count, "Existing draft returned.")
    predecessor = existing if payload.regenerate else None
    scope_snapshot["base_fingerprint"] = base_fingerprint
    scope_snapshot["regenerate_from"] = str(predecessor.id) if predecessor else None
    fingerprint = (
        _hash_snapshot({"base": base_fingerprint, "regenerate_from": str(predecessor.id)})
        if predecessor
        else base_fingerprint
    )
    provider, card_fields = await _generate_card_fields(user, db, provider, candidates)
    if not card_fields:
        raise WikiBaseError(
            502,
            "provider_invalid_response",
            "The answer provider did not return any usable flashcards",
        )
    generator_snapshot = {
        **_generator_identity(provider),
        "generated_at": datetime.now(UTC).isoformat(),
    }

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
        lifecycle="draft",
        input_fingerprint=fingerprint,
        scope_snapshot=scope_snapshot,
        generator_snapshot=generator_snapshot,
        enrollment_id=enrollment_id,
        topic_ids=topic_ids,
        predecessor_id=predecessor.id if predecessor else None,
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
    if commit:
        await db.commit()
        await db.refresh(deck, attribute_names=["cards"])
    else:
        await db.flush()
        await db.refresh(deck, attribute_names=["cards"])
    return FlashcardGenerationOutcome(
        deck=deck,
        generated_count=len(cards),
        message="Flashcard deck generated.",
    )


async def list_flashcard_decks(
    user: User, db: AsyncSession, lifecycle: str | None = None
) -> list[FlashcardDeck]:
    statement = (
        select(FlashcardDeck)
        .options(selectinload(FlashcardDeck.cards.and_(Flashcard.state == "active")))
        .where(FlashcardDeck.user_id == user.id)
        .order_by(FlashcardDeck.updated_at.desc(), FlashcardDeck.title.asc(), FlashcardDeck.id)
    )
    if lifecycle is not None:
        statement = statement.where(FlashcardDeck.lifecycle == lifecycle)
    result = await db.execute(statement)
    return list(result.scalars().unique().all())


async def list_draft_revisions(
    user: User, deck_id: uuid.UUID, db: AsyncSession
) -> list[FlashcardRevision]:
    await get_flashcard_deck(user, deck_id, db)
    result = await db.execute(
        select(FlashcardRevision)
        .where(
            FlashcardRevision.deck_id == deck_id,
            FlashcardRevision.user_id == user.id,
        )
        .order_by(FlashcardRevision.revision)
    )
    return list(result.scalars())


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


async def _lock_owned_deck(user: User, deck_id: uuid.UUID, db: AsyncSession) -> FlashcardDeck:
    deck = await db.scalar(
        select(FlashcardDeck)
        .where(FlashcardDeck.id == deck_id, FlashcardDeck.user_id == user.id)
        .with_for_update()
    )
    if deck is None:
        raise NotFoundError("Flashcard deck not found")
    await db.refresh(deck, attribute_names=["cards"])
    return deck


def _card_state(card: Flashcard) -> dict:
    return {
        "id": str(card.id),
        "deck_id": str(card.deck_id),
        "user_id": str(card.user_id),
        "source_id": str(card.source_id) if card.source_id else None,
        "source_chunk_id": str(card.source_chunk_id) if card.source_chunk_id else None,
        "wiki_page_id": str(card.wiki_page_id) if card.wiki_page_id else None,
        "order_index": card.order_index,
        "card_type": card.card_type,
        "question": card.question,
        "answer": card.answer,
        "topic_tag": card.topic_tag,
        "topic_ids": [str(value) for value in card.topic_ids],
        "tags": card.tags,
        "citation_ref": card.citation_ref,
        "citations": card.citations,
        "source_title": card.source_title,
        "location_label": card.location_label,
        "state": card.state,
        "manual_note": card.manual_note,
        "approved": card.approved,
        "created_at": card.created_at.isoformat() if card.created_at else None,
        "updated_at": card.updated_at.isoformat() if card.updated_at else None,
    }


def _deck_state(deck: FlashcardDeck) -> dict:
    return {
        "id": str(deck.id),
        "user_id": str(deck.user_id),
        "title": deck.title,
        "description": deck.description,
        "generation_scope": deck.generation_scope,
        "source_ids": [str(value) for value in deck.source_ids],
        "wiki_page_id": str(deck.wiki_page_id) if deck.wiki_page_id else None,
        "topic_tags": deck.topic_tags,
        "card_count": deck.card_count,
        "lifecycle": deck.lifecycle,
        "revision": deck.revision,
        "input_fingerprint": deck.input_fingerprint,
        "scope_snapshot": deck.scope_snapshot,
        "generator_snapshot": deck.generator_snapshot,
        "enrollment_id": str(deck.enrollment_id) if deck.enrollment_id else None,
        "topic_ids": [str(value) for value in deck.topic_ids],
        "predecessor_id": str(deck.predecessor_id) if deck.predecessor_id else None,
        "approved_at": deck.approved_at.isoformat() if deck.approved_at else None,
        "retired_at": deck.retired_at.isoformat() if deck.retired_at else None,
        "created_at": deck.created_at.isoformat() if deck.created_at else None,
        "updated_at": deck.updated_at.isoformat() if deck.updated_at else None,
        "cards": [
            _card_state(card)
            for card in sorted(deck.cards, key=lambda item: (item.order_index, str(item.id)))
        ],
    }


def _draft(deck: FlashcardDeck, expected_revision: int) -> None:
    if deck.lifecycle != "draft":
        raise WikiBaseError(409, "deck_immutable", "Only draft decks can be edited")
    if deck.revision != expected_revision:
        raise WikiBaseError(409, "revision_conflict", "Draft revision does not match")


async def _record_revision(
    deck: FlashcardDeck, user: User, action: str, before: dict, db: AsyncSession
) -> None:
    deck.revision += 1
    await db.flush()
    await db.refresh(deck)
    await db.refresh(deck, attribute_names=["cards"])
    db.add(
        FlashcardRevision(
            deck_id=deck.id,
            user_id=user.id,
            revision=deck.revision,
            action=action,
            before=before,
            after=_deck_state(deck),
        )
    )
    await db.commit()
    await db.refresh(deck)
    await db.refresh(deck, attribute_names=["cards"])


async def _validate_topics(
    deck: FlashcardDeck, topic_ids: list[uuid.UUID], user: User, db: AsyncSession
) -> None:
    if not topic_ids:
        return
    count = await db.scalar(
        select(func.count())
        .select_from(CurriculumTopic)
        .join(ModuleEnrollment, CurriculumTopic.enrollment_id == ModuleEnrollment.id)
        .where(
            CurriculumTopic.id.in_(topic_ids),
            CurriculumTopic.state == "canonical",
            CurriculumTopic.archived.is_(False),
            ModuleEnrollment.user_id == user.id,
            CurriculumTopic.enrollment_id == deck.enrollment_id,
        )
    )
    if count != len(set(topic_ids)):
        raise WikiBaseError(422, "invalid_topic", "Topics must be current canonical deck topics")


async def _canonical_citations(
    deck: FlashcardDeck,
    citations: list[dict],
    user: User,
    db: AsyncSession,
    *,
    topic_ids: list[uuid.UUID] | None = None,
) -> list[dict]:
    allowed_provenance = [
        item
        for item in deck.scope_snapshot.get("ordered_provenance", [])
        if item.get("source_id") and item.get("source_chunk_id")
    ]
    allowed_citations = {
        (
            uuid.UUID(item["source_id"]),
            uuid.UUID(item["source_chunk_id"]),
            uuid.UUID(item["wiki_page_id"]) if item.get("wiki_page_id") else None,
        )
        for item in allowed_provenance
    }
    canonical = []
    requested_topic_values = {str(topic_id) for topic_id in topic_ids or []}
    covered_topic_values: set[str] = set()
    for citation in citations:
        source_id = uuid.UUID(str(citation["source_id"]))
        chunk_id = citation.get("source_chunk_id")
        if chunk_id is None:
            raise WikiBaseError(422, "citation_not_current", "Citation chunk is not current")
        parsed_chunk_id = uuid.UUID(str(chunk_id))
        wiki_id = citation.get("wiki_page_id")
        parsed_wiki_id = uuid.UUID(str(wiki_id)) if wiki_id is not None else None
        citation_key = (source_id, parsed_chunk_id, parsed_wiki_id)
        if citation_key not in allowed_citations:
            raise WikiBaseError(422, "citation_out_of_scope", "Citation is outside the draft scope")
        matching_provenance = [
            item
            for item in allowed_provenance
            if (
                uuid.UUID(item["source_id"]),
                uuid.UUID(item["source_chunk_id"]),
                uuid.UUID(item["wiki_page_id"]) if item.get("wiki_page_id") else None,
            )
            == citation_key
        ]
        scoped_matches = [
            item for item in matching_provenance if item.get("topic_id") in requested_topic_values
        ]
        covered_topic_values.update(
            str(item["topic_id"]) for item in scoped_matches if item.get("topic_id")
        )
        if requested_topic_values and not scoped_matches:
            raise WikiBaseError(
                422,
                "citation_out_of_scope",
                "Citation does not support any selected canonical topic",
            )
        immutable_provenance = scoped_matches[0] if scoped_matches else matching_provenance[0]
        scoped_excerpts = list(
            dict.fromkeys(
                str(item.get("evidence_excerpt") or "").strip()
                for item in scoped_matches
                if str(item.get("evidence_excerpt") or "").strip()
            )
        )
        try:
            source = (await _lock_ready_sources(user, db, [source_id]))[0]
        except NotFoundError as exc:
            raise WikiBaseError(
                422, "citation_not_current", "Citation source is not current"
            ) from exc
        chunk = await db.scalar(
            select(SourceChunk)
            .where(
                SourceChunk.id == parsed_chunk_id,
                SourceChunk.source_id == source.id,
                active_source_chunk_predicate(SourceChunk, Source),
            )
            .join(Source, SourceChunk.source_id == Source.id)
        )
        if chunk is None:
            raise WikiBaseError(422, "citation_not_current", "Citation chunk is not current")
        wiki_citation = None
        if parsed_wiki_id is not None:
            wiki_citation = await db.scalar(
                select(WikiCitation)
                .join(WikiPage, WikiCitation.page_id == WikiPage.id)
                .where(
                    WikiCitation.page_id == parsed_wiki_id,
                    WikiCitation.source_id == source.id,
                    WikiCitation.source_chunk_id == chunk.id,
                    WikiPage.user_id == user.id,
                    WikiPage.is_current.is_(True),
                )
            )
            if wiki_citation is None:
                raise WikiBaseError(422, "citation_not_current", "Wiki citation is not current")
        canonical.append(
            {
                "source_id": str(source.id),
                "source_chunk_id": str(chunk.id),
                "wiki_page_id": str(parsed_wiki_id) if parsed_wiki_id else None,
                "citation_ref": wiki_citation.citation_ref if wiki_citation else chunk.citation_ref,
                "source_title": wiki_citation.source_title if wiki_citation else source.title,
                "location_label": (
                    wiki_citation.location_label if wiki_citation else chunk.location_label
                ),
                "excerpt": "\n\n".join(scoped_excerpts)
                or immutable_provenance.get("evidence_excerpt")
                or chunk.content,
            }
        )
    if requested_topic_values - covered_topic_values:
        raise WikiBaseError(
            422,
            "citation_out_of_scope",
            "Citations do not support every selected canonical topic",
        )
    return canonical


def _validate_supported(citations: list[dict], manual_note: bool) -> None:
    if not citations and not manual_note:
        raise WikiBaseError(
            422,
            "unsupported_card",
            "Evidence-backed cards require a selected citation; "
            "otherwise mark a manual personal note",
        )


async def update_draft_title(
    user: User, deck_id: uuid.UUID, title: str, expected_revision: int, db: AsyncSession
) -> FlashcardDeck:
    deck = await _lock_owned_deck(user, deck_id, db)
    _draft(deck, expected_revision)
    before = _deck_state(deck)
    deck.title = title.strip()
    await _record_revision(deck, user, "edit_deck", before, db)
    return deck


async def update_draft_card(
    user: User,
    deck_id: uuid.UUID,
    card_id: uuid.UUID,
    payload: DraftCardUpdate,
    db: AsyncSession,
) -> FlashcardDeck:
    deck = await _lock_owned_deck(user, deck_id, db)
    _draft(deck, payload.expected_revision)
    card = next((item for item in deck.cards if item.id == card_id), None)
    if card is None:
        raise NotFoundError("Flashcard not found")
    before = _deck_state(deck)
    values = payload.model_dump(exclude_unset=True, exclude={"expected_revision"})
    citations = values.get("citations", card.citations)
    manual_note = values.get("manual_note", card.manual_note)
    _validate_supported(citations, manual_note)
    topic_ids = values.get("topic_ids", card.topic_ids)
    await _validate_topics(deck, topic_ids, user, db)
    citations = await _canonical_citations(deck, citations, user, db, topic_ids=topic_ids)
    if "citations" in values:
        values["citations"] = citations
    for field, value in values.items():
        setattr(card, field, value)
    if "citations" in values:
        first_citation = citations[0] if citations else {}
        card.source_id = uuid.UUID(str(first_citation["source_id"])) if first_citation else None
        card.source_chunk_id = (
            uuid.UUID(str(first_citation["source_chunk_id"]))
            if first_citation.get("source_chunk_id")
            else None
        )
        card.wiki_page_id = (
            uuid.UUID(str(first_citation["wiki_page_id"]))
            if first_citation.get("wiki_page_id")
            else None
        )
        card.citation_ref = first_citation.get("citation_ref", "")
        card.source_title = first_citation.get("source_title", "")
        card.location_label = first_citation.get("location_label", "")
    card.approved = False
    await _record_revision(deck, user, "edit_card", before, db)
    return deck


async def add_draft_card(
    user: User, deck_id: uuid.UUID, payload: DraftCardAdd, db: AsyncSession
) -> FlashcardDeck:
    deck = await _lock_owned_deck(user, deck_id, db)
    _draft(deck, payload.expected_revision)
    requested_citations = [citation.model_dump(mode="json") for citation in payload.citations]
    _validate_supported(requested_citations, payload.manual_note)
    citations = await _canonical_citations(
        deck, requested_citations, user, db, topic_ids=payload.topic_ids
    )
    await _validate_topics(deck, payload.topic_ids, user, db)
    before = _deck_state(deck)
    first_citation = citations[0] if citations else {}
    card = Flashcard(
        deck_id=deck.id,
        user_id=user.id,
        order_index=max((item.order_index for item in deck.cards), default=0) + 1,
        source_id=uuid.UUID(str(first_citation["source_id"])) if first_citation else None,
        source_chunk_id=(
            uuid.UUID(str(first_citation["source_chunk_id"]))
            if first_citation.get("source_chunk_id")
            else None
        ),
        wiki_page_id=(
            uuid.UUID(str(first_citation["wiki_page_id"]))
            if first_citation.get("wiki_page_id")
            else None
        ),
        card_type="manual",
        question=payload.question,
        answer=payload.answer,
        topic_tag="personal-note" if payload.manual_note else "general",
        topic_ids=payload.topic_ids,
        tags=payload.tags,
        citation_ref=(first_citation.get("citation_ref", "") if first_citation else ""),
        citations=citations,
        source_title=(
            "Personal note" if payload.manual_note else first_citation.get("source_title", "")
        ),
        location_label=first_citation.get("location_label", ""),
        manual_note=payload.manual_note,
    )
    db.add(card)
    deck.cards.append(card)
    deck.card_count += 1
    await db.flush()
    await _record_revision(deck, user, "add_card", before, db)
    return deck


async def mutate_draft_cards(
    user: User,
    deck_id: uuid.UUID,
    action: str,
    card_ids: list[uuid.UUID] | None,
    expected_revision: int,
    db: AsyncSession,
    *,
    rejection_reason: str | None = None,
) -> FlashcardDeck:
    deck = await _lock_owned_deck(user, deck_id, db)
    _draft(deck, expected_revision)
    cards = {card.id: card for card in deck.cards}
    if card_ids is None:
        target_state = "discarded" if action == "restore" else "active"
        card_ids = [card.id for card in deck.cards if card.state == target_state]
    if len(set(card_ids)) != len(card_ids) or any(card_id not in cards for card_id in card_ids):
        raise WikiBaseError(422, "invalid_card_selection", "Card selection must match this draft")
    before = _deck_state(deck)
    if action == "reorder":
        active_ids = {card.id for card in deck.cards if card.state == "active"}
        if set(card_ids) != active_ids:
            raise WikiBaseError(
                422, "invalid_order", "Order must contain every active card exactly once"
            )
        for index, card_id in enumerate(card_ids, 1):
            cards[card_id].order_index = index
    elif action in {"discard", "restore"}:
        if action == "restore":
            active_cards = sorted(
                (card for card in deck.cards if card.state == "active"),
                key=lambda card: (card.order_index, str(card.id)),
            )
            restored_cards = sorted(
                (cards[card_id] for card_id in card_ids),
                key=lambda card: (card.order_index, str(card.id)),
            )
            for index, card in enumerate([*active_cards, *restored_cards], 1):
                card.order_index = index
        state = "discarded" if action == "discard" else "active"
        for card_id in card_ids:
            cards[card_id].state = state
            cards[card_id].approved = False
            if action == "discard" and rejection_reason is not None:
                cards[card_id].tags = [
                    tag for tag in cards[card_id].tags if not tag.startswith("rejected:")
                ] + [f"rejected:{rejection_reason}"]
    elif action == "approve":
        for card_id in card_ids:
            card = cards[card_id]
            if card.state != "active":
                raise WikiBaseError(422, "discarded_card", "Discarded cards cannot be approved")
            _validate_supported(card.citations, card.manual_note)
            card.citations = await _canonical_citations(
                deck, card.citations, user, db, topic_ids=card.topic_ids
            )
            await _validate_topics(deck, card.topic_ids, user, db)
            card.approved = True
    deck.card_count = sum(card.state == "active" for card in deck.cards)
    await _record_revision(deck, user, action, before, db)
    return deck


async def transition_flashcard_deck(
    user: User,
    deck_id: uuid.UUID,
    lifecycle: str,
    db: AsyncSession,
    expected_revision: int | None = None,
) -> FlashcardDeck:
    deck = await _lock_owned_deck(user, deck_id, db)
    if lifecycle == "approved" and deck.lifecycle == "approved":
        return deck
    if expected_revision is not None and deck.revision != expected_revision:
        raise WikiBaseError(409, "revision_conflict", "Draft revision does not match")
    if lifecycle == "approved":
        _draft(deck, expected_revision or 0)
        active = [card for card in deck.cards if card.state == "active"]
        if not active:
            raise WikiBaseError(422, "empty_draft", "An empty draft cannot be published")
        for card in active:
            if not card.approved:
                raise WikiBaseError(422, "card_not_approved", "All active cards must be approved")
            _validate_supported(card.citations, card.manual_note)
            card.citations = await _canonical_citations(
                deck, card.citations, user, db, topic_ids=card.topic_ids
            )
            await _validate_topics(deck, card.topic_ids, user, db)
        before = _deck_state(deck)
        await db.flush()
        await db.refresh(deck, attribute_names=["cards"])
        published_at = datetime.now(UTC)
        deck.lifecycle = "approved"
        deck.approved_at = published_at
        deck.updated_at = published_at
        deck.card_count = len(active)
        deck.revision += 1
        deck.approved_snapshot = _deck_state(deck)
        db.add(
            FlashcardRevision(
                deck_id=deck.id,
                user_id=user.id,
                revision=deck.revision,
                action="publish",
                before=before,
                after=deck.approved_snapshot,
            )
        )
        await db.commit()
        await db.refresh(deck)
        await db.refresh(deck, attribute_names=["cards"])
        return deck
    allowed = {"draft": {"archived"}, "approved": {"retired"}}
    if deck.lifecycle == "draft":
        _draft(deck, expected_revision or 0)
    if lifecycle not in allowed.get(deck.lifecycle, set()):
        raise WikiBaseError(409, "invalid_deck_transition", "Deck transition is not allowed")
    before = _deck_state(deck)
    deck.lifecycle = lifecycle
    if lifecycle == "retired":
        deck.retired_at = datetime.now(UTC)
    await _record_revision(deck, user, lifecycle, before, db)
    return deck


async def log_flashcard_attempt(
    user: User,
    card_id: uuid.UUID,
    payload: FlashcardAttemptCreate,
    idempotency_key: str | None,
    db: AsyncSession,
) -> FlashcardAttempt:
    if payload.rating is not None and idempotency_key is None:
        raise WikiBaseError(422, "missing_idempotency_key", "Idempotency-Key is required")
    if idempotency_key is None:
        idempotency_key = f"legacy:{uuid.uuid4()}"
    elif not idempotency_key.strip() or len(idempotency_key) > 128:
        raise WikiBaseError(422, "invalid_idempotency_key", "A bounded Idempotency-Key is required")
    request_hash = _hash_snapshot({"card_id": str(card_id), **payload.model_dump(mode="json")})
    await db.execute(
        select(
            func.pg_advisory_xact_lock(
                func.hashtextextended(f"rating:{user.id}:{idempotency_key}", 0)
            )
        )
    )
    existing = await db.scalar(
        select(FlashcardAttempt).where(
            FlashcardAttempt.user_id == user.id,
            FlashcardAttempt.idempotency_key == idempotency_key,
        )
    )
    if existing is not None:
        if existing.request_hash != request_hash:
            raise WikiBaseError(409, "idempotency_conflict", "Idempotency-Key was reused")
        await db.refresh(existing, attribute_names=["evidence"])
        return existing

    deck_id = await db.scalar(
        select(Flashcard.deck_id).where(
            Flashcard.id == card_id,
            Flashcard.user_id == user.id,
            Flashcard.state == "active",
        )
    )
    if deck_id is None:
        raise NotFoundError("Flashcard not found")
    deck = await db.scalar(
        select(FlashcardDeck)
        .where(FlashcardDeck.id == deck_id, FlashcardDeck.user_id == user.id)
        .with_for_update()
    )
    if deck is None or deck.lifecycle != "approved":
        raise WikiBaseError(
            409, "deck_not_approved", "Draft, retired, or archived decks cannot be practiced"
        )
    card = await db.scalar(
        select(Flashcard).where(
            Flashcard.id == card_id,
            Flashcard.deck_id == deck.id,
            Flashcard.user_id == user.id,
            Flashcard.state == "active",
        )
    )
    if card is None:
        raise NotFoundError("Flashcard not found")
    rating = payload.rating or ("Good" if payload.is_correct else "Again")
    ease_by_rating = {"Again": 1, "Hard": 2, "Good": 3, "Easy": 5}
    is_correct = rating != "Again"
    attempt = FlashcardAttempt(
        user_id=user.id,
        deck_id=card.deck_id,
        card_id=card.id,
        answer_text=payload.answer_text,
        rating=rating,
        ease=ease_by_rating[rating],
        idempotency_key=idempotency_key,
        request_hash=request_hash,
        is_correct=is_correct,
        confidence=ease_by_rating[rating],
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
        is_correct=is_correct,
        confidence=ease_by_rating[rating],
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
        statement = statement.where(func.lower(LearningEvidence.topic_tag) == topic_tag.lower())
    statement = statement.order_by(LearningEvidence.occurred_at.desc()).limit(limit)
    result = await db.execute(statement)
    return list(result.scalars().all())
