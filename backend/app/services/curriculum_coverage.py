import hashlib
import heapq
import json
import math
import re
import uuid
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError, WikiBaseError
from app.models.curriculum import CurriculumTopic, ModuleEnrollment, TopicSourceAssociation
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk, active_source_chunk_predicate
from app.models.user import User

PROPOSAL_ALGORITHM = "canonical-title-overlap-v1"
RULE_DEFINITION = (
    "unicode-casefold;alphanumeric-tokens;english-stopwords;phrase-or-75pct-overlap;"
    "minimum-two-meaningful-tokens;ready-sources-only"
)
RULE_HASH = hashlib.sha256(f"{PROPOSAL_ALGORITHM}:{RULE_DEFINITION}".encode()).hexdigest()
MANUAL_ALGORITHM = "manual-source-review-v1"
MANUAL_RULE_HASH = hashlib.sha256(MANUAL_ALGORITHM.encode()).hexdigest()
STOP_WORDS = frozenset(
    {
        "a",
        "an",
        "and",
        "are",
        "as",
        "at",
        "be",
        "by",
        "for",
        "from",
        "in",
        "into",
        "is",
        "it",
        "of",
        "on",
        "or",
        "that",
        "the",
        "their",
        "this",
        "to",
        "using",
        "with",
    }
)
TOKEN_RE = re.compile(r"[^\W_]+", re.UNICODE)
CANDIDATE_CHUNK_BATCH_SIZE = 500
CANDIDATE_CHUNK_LIMIT = 100
CANDIDATE_SCORING_CHAR_LIMIT = 8_000


def normalized_tokens(value: str) -> tuple[str, ...]:
    return tuple(
        token
        for token in (match.group(0).casefold() for match in TOKEN_RE.finditer(value))
        if len(token) >= 3 and token not in STOP_WORDS
    )


def topic_fingerprint(topic: CurriculumTopic) -> str:
    value = json.dumps(
        {"title": topic.title, "source_sha256": topic.source_sha256},
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(value.encode()).hexdigest()


def source_fingerprint(chunks: list[SourceChunk]) -> str:
    payload = [
        {
            "id": str(chunk.id),
            "index": chunk.chunk_index,
            "citation": chunk.citation_ref,
            "location": chunk.location_label,
            "content": chunk.content,
        }
        for chunk in sorted(chunks, key=lambda item: (item.chunk_index, str(item.id)))
    ]
    return hashlib.sha256(
        json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def _excerpt(content: str, matched_tokens: set[str], *, limit: int = 320) -> str:
    positions = [
        match.start()
        for match in TOKEN_RE.finditer(content)
        if match.group(0).casefold() in matched_tokens
    ]
    center = positions[0] if positions else 0
    start = max(0, center - limit // 3)
    end = min(len(content), start + limit)
    start = max(0, end - limit)
    excerpt = re.sub(r"\s+", " ", content[start:end]).strip()
    if start:
        excerpt = "…" + excerpt
    if end < len(content):
        excerpt += "…"
    return excerpt


def match_topic_to_chunks(topic_title: str, chunks: list[SourceChunk]) -> tuple[float, list[dict]]:
    topic_tokens = normalized_tokens(topic_title)
    unique_topic_tokens = set(topic_tokens)
    if len(unique_topic_tokens) < 2:
        return 0.0, []
    required = (
        len(unique_topic_tokens)
        if len(unique_topic_tokens) <= 3
        else math.ceil(len(unique_topic_tokens) * 0.75)
    )
    normalized_phrase = " ".join(topic_tokens)
    evidence: list[dict] = []
    best_strength = 0.0
    for chunk in sorted(chunks, key=lambda item: (item.chunk_index, str(item.id))):
        chunk_tokens = normalized_tokens(chunk.content)
        chunk_token_set = set(chunk_tokens)
        matched = unique_topic_tokens & chunk_token_set
        phrase_match = normalized_phrase in " ".join(chunk_tokens)
        if not phrase_match and len(matched) < required:
            continue
        strength = len(matched) / len(unique_topic_tokens)
        best_strength = max(best_strength, strength)
        evidence.append(
            {
                "chunk_id": str(chunk.id),
                "citation": chunk.citation_ref,
                "excerpt": _excerpt(chunk.content, matched),
                "location": chunk.location_label,
            }
        )
        if len(evidence) == 3:
            break
    return round(best_strength, 4), evidence


async def _chunks_by_source(db: AsyncSession, source_ids: list[uuid.UUID]) -> dict[uuid.UUID, list]:
    result = {source_id: [] for source_id in source_ids}
    if not source_ids:
        return result
    chunks = list(
        (
            await db.execute(
                select(SourceChunk)
                .join(Source, Source.id == SourceChunk.source_id)
                .where(
                    SourceChunk.source_id.in_(source_ids),
                    active_source_chunk_predicate(SourceChunk, Source),
                )
                .order_by(SourceChunk.source_id, SourceChunk.chunk_index, SourceChunk.id)
            )
        ).scalars()
    )
    for chunk in chunks:
        result[chunk.source_id].append(chunk)
    return result


def _stored_evidence_is_current(row: TopicSourceAssociation, chunks: list[SourceChunk]) -> bool:
    chunks_by_id = {str(chunk.id): chunk for chunk in chunks}
    if not row.evidence:
        return False
    for item in row.evidence:
        chunk = chunks_by_id.get(str(item.get("chunk_id", "")))
        if chunk is None:
            return False
        excerpt = re.sub(r"\s+", " ", str(item.get("excerpt", ""))).strip(" …")
        content = re.sub(r"\s+", " ", chunk.content)
        if (
            not excerpt
            or excerpt not in content
            or item.get("citation") != chunk.citation_ref
            or item.get("location") != chunk.location_label
        ):
            return False
    return True


def _association_staleness(
    row: TopicSourceAssociation,
    enrollment: ModuleEnrollment,
    topic: CurriculumTopic | None,
    source: Source | None,
    chunks: list[SourceChunk],
) -> tuple[bool, str | None]:
    if enrollment.archived:
        return True, "enrollment_archived"
    if topic is None or topic.archived:
        return True, "topic_archived_or_missing"
    if source is None:
        return True, "source_missing"
    if source.user_id != enrollment.user_id:
        return True, "source_not_owned"
    if source.enrollment_id not in {None, enrollment.id}:
        return True, "source_scope_changed"
    if source.status == SourceStatus.ARCHIVED:
        return True, "source_archived"
    if source.status in {SourceStatus.PENDING, SourceStatus.INDEXING}:
        return True, "source_processing"
    if source.status == SourceStatus.FAILED:
        return True, "source_failed"
    if row.stale:
        return True, row.stale_reason or "association_stale"
    if row.topic_fingerprint != topic_fingerprint(topic):
        return True, "topic_revised"
    if row.method == "manual":
        if not _stored_evidence_is_current(row, chunks):
            return True, "stored_evidence_changed"
        return False, None
    if row.algorithm != PROPOSAL_ALGORITHM or row.rule_hash != RULE_HASH:
        return True, "proposal_rule_changed"
    if row.source_fingerprint != source_fingerprint(chunks):
        return True, "source_chunks_changed"
    if not _stored_evidence_is_current(row, chunks):
        return True, "stored_evidence_changed"
    return False, None


async def generate_proposals(
    enrollment: ModuleEnrollment,
    source_ids: list[uuid.UUID],
    user: User,
    db: AsyncSession,
) -> dict[str, Any]:
    if enrollment.archived:
        raise WikiBaseError(409, "enrollment_archived", "Archived enrollments cannot be mapped")
    await db.execute(
        select(ModuleEnrollment.id).where(ModuleEnrollment.id == enrollment.id).with_for_update()
    )
    topics = list(
        (
            await db.execute(
                select(CurriculumTopic)
                .where(
                    CurriculumTopic.enrollment_id == enrollment.id,
                    CurriculumTopic.archived.is_(False),
                    CurriculumTopic.state == "canonical",
                )
                .order_by(CurriculumTopic.id)
                .with_for_update()
            )
        ).scalars()
    )
    association_source_ids = set(
        (
            await db.execute(
                select(TopicSourceAssociation.source_id).where(
                    TopicSourceAssociation.enrollment_id == enrollment.id
                )
            )
        ).scalars()
    )
    scoped_source_ids = set(
        (
            await db.execute(
                select(Source.id).where(
                    Source.user_id == user.id,
                    Source.enrollment_id == enrollment.id,
                )
            )
        ).scalars()
    )
    sources = list(
        (
            await db.execute(
                select(Source)
                .where(Source.id.in_(set(source_ids) | association_source_ids | scoped_source_ids))
                .order_by(Source.id)
                .with_for_update()
            )
        ).scalars()
    )
    source_by_id = {source.id: source for source in sources}
    explicit_sources = [source_by_id.get(source_id) for source_id in source_ids]
    if any(source is None or source.user_id != user.id for source in explicit_sources):
        raise NotFoundError("Source not found")
    if any(source.enrollment_id not in {None, enrollment.id} for source in explicit_sources):
        raise WikiBaseError(
            409,
            "source_scope_conflict",
            "A source attached to another enrollment cannot be reassigned implicitly",
        )
    existing = list(
        (
            await db.execute(
                select(TopicSourceAssociation)
                .where(TopicSourceAssociation.enrollment_id == enrollment.id)
                .order_by(TopicSourceAssociation.id)
                .with_for_update()
            )
        ).scalars()
    )
    sources = [
        source
        for source in sources
        if source.user_id == user.id
        and source.status != SourceStatus.ARCHIVED
        and source.enrollment_id in {None, enrollment.id}
    ]
    topics.sort(key=lambda topic: (topic.position, str(topic.id)))
    ready_sources = [source for source in sources if source.status == SourceStatus.READY]
    chunks_by_source = await _chunks_by_source(db, [source.id for source in ready_sources])
    existing_by_pair = {(row.topic_id, row.source_id): row for row in existing}
    created = updated = unchanged = protected = 0
    matched_pairs: set[tuple[uuid.UUID, uuid.UUID]] = set()
    now = datetime.now(UTC)

    for topic in topics:
        current_topic_fingerprint = topic_fingerprint(topic)
        for source in ready_sources:
            chunks = chunks_by_source[source.id]
            strength, evidence = match_topic_to_chunks(topic.title, chunks)
            if not evidence:
                continue
            pair = (topic.id, source.id)
            matched_pairs.add(pair)
            current_source_fingerprint = source_fingerprint(chunks)
            row = existing_by_pair.get(pair)
            values = {
                "evidence_strength": strength,
                "algorithm": PROPOSAL_ALGORITHM,
                "rule_hash": RULE_HASH,
                "source_fingerprint": current_source_fingerprint,
                "topic_fingerprint": current_topic_fingerprint,
                "evidence": evidence,
                "reason_code": "meaningful_title_overlap",
                "stale": False,
                "stale_reason": None,
                "updated_at": now,
            }
            if row is None:
                row = TopicSourceAssociation(
                    enrollment_id=enrollment.id,
                    topic_id=topic.id,
                    source_id=source.id,
                    status="proposed",
                    method="deterministic",
                    **values,
                )
                db.add(row)
                existing_by_pair[pair] = row
                created += 1
            elif row.status != "proposed":
                protected += 1
            elif all(
                getattr(row, key) == value for key, value in values.items() if key != "updated_at"
            ):
                unchanged += 1
            else:
                for key, value in values.items():
                    setattr(row, key, value)
                updated += 1

    for pair, row in existing_by_pair.items():
        if row.status != "proposed" or pair in matched_pairs:
            continue
        source = next((item for item in sources if item.id == row.source_id), None)
        topic = next((item for item in topics if item.id == row.topic_id), None)
        if source is None or topic is None:
            reason = "scope_or_archive_changed"
        elif source.status in {SourceStatus.PENDING, SourceStatus.INDEXING}:
            reason = "source_processing"
        elif source.status == SourceStatus.FAILED:
            reason = "source_failed"
        else:
            reason = "evidence_no_longer_matches"
        if not row.stale or row.stale_reason != reason:
            row.stale = True
            row.stale_reason = reason
            row.updated_at = now
            updated += 1
        else:
            unchanged += 1

    topic_by_id = {topic.id: topic for topic in topics}
    all_source_by_id = {source.id: source for source in sources}
    for row in existing:
        if row.status == "proposed":
            continue
        stale, stale_reason = _association_staleness(
            row,
            enrollment,
            topic_by_id.get(row.topic_id),
            all_source_by_id.get(row.source_id),
            chunks_by_source.get(row.source_id, []),
        )
        if stale and (not row.stale or row.stale_reason != stale_reason):
            row.stale = True
            row.stale_reason = stale_reason
            row.updated_at = now
            updated += 1
    await db.flush()
    return {
        "created": created,
        "updated": updated,
        "unchanged": unchanged,
        "protected_decisions": protected,
        "associations": list(existing_by_pair.values()),
    }


async def add_manual_association(
    enrollment: ModuleEnrollment,
    topic_id: uuid.UUID,
    source_id: uuid.UUID,
    chunk_ids: list[uuid.UUID],
    reason_code: str,
    user: User,
    db: AsyncSession,
) -> TopicSourceAssociation:
    if enrollment.archived:
        raise WikiBaseError(409, "enrollment_archived", "Archived enrollments cannot be mapped")
    await db.execute(
        select(ModuleEnrollment.id).where(ModuleEnrollment.id == enrollment.id).with_for_update()
    )
    topic = await db.scalar(
        select(CurriculumTopic)
        .where(
            CurriculumTopic.id == topic_id,
            CurriculumTopic.enrollment_id == enrollment.id,
            CurriculumTopic.archived.is_(False),
        )
        .with_for_update()
    )
    if topic is None:
        raise WikiBaseError(400, "invalid_topic_id", "Topic does not belong to this enrollment")
    source = await db.scalar(
        select(Source).where(Source.id == source_id, Source.user_id == user.id).with_for_update()
    )
    if source is None:
        raise NotFoundError("Source not found")
    if source.enrollment_id not in {None, enrollment.id}:
        raise WikiBaseError(
            409,
            "source_scope_conflict",
            "A source attached to another enrollment cannot be reassigned implicitly",
        )
    if source.status != SourceStatus.READY:
        raise WikiBaseError(409, "source_not_ready", "Only READY sources can be confirmed")
    chunks = list(
        (
            await db.execute(
                select(SourceChunk)
                .join(Source, Source.id == SourceChunk.source_id)
                .where(
                    SourceChunk.source_id == source.id,
                    active_source_chunk_predicate(SourceChunk, Source),
                )
                .order_by(SourceChunk.chunk_index, SourceChunk.id)
            )
        ).scalars()
    )
    selected = [chunk for chunk in chunks if chunk.id in set(chunk_ids)]
    if len(selected) != len(chunk_ids):
        raise WikiBaseError(400, "invalid_chunk_id", "Chunk does not belong to the source")
    evidence = [
        {
            "chunk_id": str(chunk.id),
            "citation": chunk.citation_ref,
            "excerpt": _excerpt(chunk.content, set(normalized_tokens(topic.title))),
            "location": chunk.location_label,
        }
        for chunk in selected
    ]
    row = await db.scalar(
        select(TopicSourceAssociation)
        .where(
            TopicSourceAssociation.topic_id == topic.id,
            TopicSourceAssociation.source_id == source.id,
        )
        .with_for_update()
    )
    now = datetime.now(UTC)
    if row is None:
        row = TopicSourceAssociation(
            enrollment_id=enrollment.id,
            topic_id=topic.id,
            source_id=source.id,
            created_at=now,
        )
        db.add(row)
    row.status = "confirmed"
    row.method = "manual"
    row.evidence_strength = 1.0 if evidence else 0.5
    row.algorithm = MANUAL_ALGORITHM
    row.rule_hash = MANUAL_RULE_HASH
    row.source_fingerprint = source_fingerprint(chunks)
    row.topic_fingerprint = topic_fingerprint(topic)
    row.evidence = evidence
    row.reason_code = reason_code
    row.stale = False
    row.stale_reason = None
    row.updated_at = now
    row.reviewed_at = now
    row.reviewer_id = user.id
    await db.flush()
    return row


async def decide_association(
    enrollment: ModuleEnrollment,
    association_id: uuid.UUID,
    decision: str,
    user: User,
    db: AsyncSession,
) -> TopicSourceAssociation:
    if enrollment.archived:
        raise WikiBaseError(409, "enrollment_archived", "Archived enrollments cannot be mapped")
    await db.execute(
        select(ModuleEnrollment.id).where(ModuleEnrollment.id == enrollment.id).with_for_update()
    )
    identifiers = (
        await db.execute(
            select(TopicSourceAssociation.topic_id, TopicSourceAssociation.source_id).where(
                TopicSourceAssociation.id == association_id,
                TopicSourceAssociation.enrollment_id == enrollment.id,
            )
        )
    ).one_or_none()
    if identifiers is None:
        raise NotFoundError("Association not found")
    topic = await db.scalar(
        select(CurriculumTopic)
        .where(
            CurriculumTopic.id == identifiers.topic_id,
            CurriculumTopic.enrollment_id == enrollment.id,
            CurriculumTopic.archived.is_(False),
        )
        .with_for_update()
    )
    if topic is None:
        raise WikiBaseError(409, "topic_archived", "Archived topics cannot be mapped")
    source = await db.scalar(
        select(Source)
        .where(Source.id == identifiers.source_id, Source.user_id == user.id)
        .with_for_update()
    )
    if source is None:
        raise NotFoundError("Source not found")
    if source.enrollment_id not in {None, enrollment.id}:
        raise WikiBaseError(409, "source_scope_conflict", "Source is outside this enrollment")
    row = await db.scalar(
        select(TopicSourceAssociation)
        .where(
            TopicSourceAssociation.id == association_id,
            TopicSourceAssociation.enrollment_id == enrollment.id,
        )
        .with_for_update()
    )
    if row is None:
        raise NotFoundError("Association not found")
    if row.status != "proposed":
        raise WikiBaseError(409, "association_already_reviewed", "Association is already reviewed")
    if decision == "confirm":
        chunks = list(
            (
                await db.execute(
                    select(SourceChunk)
                    .join(Source, Source.id == SourceChunk.source_id)
                    .where(
                        SourceChunk.source_id == source.id,
                        active_source_chunk_predicate(SourceChunk, Source),
                    )
                    .order_by(SourceChunk.chunk_index, SourceChunk.id)
                )
            ).scalars()
        )
        stale, _ = _association_staleness(row, enrollment, topic, source, chunks)
        if stale:
            raise WikiBaseError(
                409, "stale_evidence", "Recompute stale evidence before confirming it"
            )
    row.status = "confirmed" if decision == "confirm" else "rejected"
    row.reason_code = "user_confirmed" if decision == "confirm" else "user_rejected"
    row.reviewed_at = datetime.now(UTC)
    row.updated_at = row.reviewed_at
    row.reviewer_id = user.id
    await db.flush()
    return row


def _association_payload(
    row: TopicSourceAssociation,
    source: Source,
    *,
    stale: bool,
    stale_reason: str | None,
) -> dict[str, Any]:
    return {
        "id": row.id,
        "topic_id": row.topic_id,
        "source_id": row.source_id,
        "source_title": source.title,
        "source_status": source.status.value,
        "status": row.status,
        "method": row.method,
        "evidence_strength": row.evidence_strength,
        "algorithm": row.algorithm,
        "rule_hash": row.rule_hash,
        "source_fingerprint": row.source_fingerprint,
        "topic_fingerprint": row.topic_fingerprint,
        "evidence": row.evidence,
        "reason_code": row.reason_code,
        "stale": stale,
        "stale_reason": stale_reason,
        "created_at": row.created_at,
        "reviewed_at": row.reviewed_at,
        "reviewer_id": row.reviewer_id,
    }


async def association_payload(
    row: TopicSourceAssociation, enrollment: ModuleEnrollment, db: AsyncSession
) -> dict[str, Any]:
    source = await db.scalar(
        select(Source).where(Source.id == row.source_id, Source.user_id == enrollment.user_id)
    )
    if source is None:
        raise NotFoundError("Source not found")
    if source.enrollment_id not in {None, enrollment.id}:
        raise WikiBaseError(409, "source_scope_conflict", "Source is outside this enrollment")
    topic = await db.scalar(
        select(CurriculumTopic).where(
            CurriculumTopic.id == row.topic_id,
            CurriculumTopic.enrollment_id == enrollment.id,
        )
    )
    chunks = (await _chunks_by_source(db, [source.id]))[source.id]
    stale, stale_reason = _association_staleness(row, enrollment, topic, source, chunks)
    return _association_payload(row, source, stale=stale, stale_reason=stale_reason)


async def current_confirmed_source_ids(
    enrollment: ModuleEnrollment, db: AsyncSession
) -> set[uuid.UUID]:
    topics = list(
        (
            await db.execute(
                select(CurriculumTopic).where(
                    CurriculumTopic.enrollment_id == enrollment.id,
                    CurriculumTopic.archived.is_(False),
                )
            )
        ).scalars()
    )
    if enrollment.archived or not topics:
        return set()
    topic_by_id = {topic.id: topic for topic in topics}
    associations = list(
        (
            await db.execute(
                select(TopicSourceAssociation).where(
                    TopicSourceAssociation.enrollment_id == enrollment.id,
                    TopicSourceAssociation.status == "confirmed",
                )
            )
        ).scalars()
    )
    sources = list(
        (
            await db.execute(
                select(Source).where(
                    Source.id.in_({row.source_id for row in associations}),
                    Source.user_id == enrollment.user_id,
                    Source.enrollment_id.is_(None),
                )
            )
        ).scalars()
    )
    source_by_id = {source.id: source for source in sources}
    chunks_by_source = await _chunks_by_source(db, list(source_by_id))
    current: set[uuid.UUID] = set()
    for row in associations:
        source = source_by_id.get(row.source_id)
        topic = topic_by_id.get(row.topic_id)
        if source is None or topic is None:
            continue
        stale, _ = _association_staleness(
            row, enrollment, topic, source, chunks_by_source[source.id]
        )
        if not stale:
            current.add(source.id)
    return current


async def coverage_dashboard(enrollment: ModuleEnrollment, db: AsyncSession) -> dict[str, Any]:
    topics = list(
        (
            await db.execute(
                select(CurriculumTopic)
                .where(
                    CurriculumTopic.enrollment_id == enrollment.id,
                    CurriculumTopic.archived.is_(False),
                )
                .order_by(CurriculumTopic.position, CurriculumTopic.id)
            )
        ).scalars()
    )
    if enrollment.archived:
        topics = []
    associations = list(
        (
            await db.execute(
                select(TopicSourceAssociation).where(
                    TopicSourceAssociation.enrollment_id == enrollment.id,
                    TopicSourceAssociation.status.in_(["proposed", "confirmed"]),
                )
            )
        ).scalars()
    )
    sources = list(
        (
            await db.execute(
                select(Source).where(
                    Source.id.in_({row.source_id for row in associations}),
                    Source.user_id == enrollment.user_id,
                )
            )
        ).scalars()
    )
    source_by_id = {source.id: source for source in sources}
    chunks_by_source = await _chunks_by_source(db, list(source_by_id))
    by_topic: dict[uuid.UUID, list[dict[str, Any]]] = {}
    inaccessible_by_topic: dict[uuid.UUID, set[str]] = {}
    topic_by_id = {topic.id: topic for topic in topics}
    for row in associations:
        source = source_by_id.get(row.source_id)
        topic = topic_by_id.get(row.topic_id)
        if topic is None:
            continue
        if source is None:
            inaccessible_by_topic.setdefault(row.topic_id, set()).add("source_not_owned")
            continue
        if source.enrollment_id not in {None, enrollment.id}:
            inaccessible_by_topic.setdefault(row.topic_id, set()).add("source_scope_changed")
            continue
        stale, stale_reason = _association_staleness(
            row, enrollment, topic, source, chunks_by_source[source.id]
        )
        by_topic.setdefault(row.topic_id, []).append(
            _association_payload(row, source, stale=stale, stale_reason=stale_reason)
        )

    scoped_sources = list(
        (
            await db.execute(
                select(Source).where(
                    Source.user_id == enrollment.user_id,
                    Source.enrollment_id == enrollment.id,
                    Source.status != SourceStatus.ARCHIVED,
                )
            )
        ).scalars()
    )
    rows = []
    numerator = 0
    for topic in topics:
        evidence = by_topic.get(topic.id, [])
        confirmed = [item for item in evidence if item["status"] == "confirmed"]
        current_confirmed = [item for item in confirmed if not item["stale"]]
        proposed = [item for item in evidence if item["status"] == "proposed"]
        current_proposals = [item for item in proposed if not item["stale"]]
        if current_confirmed:
            state = "covered"
            reason_codes: list[str] = []
            numerator += 1
        elif current_proposals:
            state = "review"
            reason_codes = ["proposal_requires_review"]
        else:
            state = "missing"
            reason_codes = sorted(
                {
                    item["stale_reason"]
                    for item in evidence
                    if item["stale"] and item["stale_reason"]
                }
                | inaccessible_by_topic.get(topic.id, set())
            )
            if not reason_codes:
                if any(
                    source.status in {SourceStatus.PENDING, SourceStatus.INDEXING}
                    for source in scoped_sources
                ):
                    reason_codes.append("source_processing")
                if any(source.status == SourceStatus.FAILED for source in scoped_sources):
                    reason_codes.append("source_failed")
                if not reason_codes:
                    reason_codes.append(
                        "no_attached_sources" if not scoped_sources else "no_matching_evidence"
                    )
        rows.append(
            {
                "topic_id": topic.id,
                "position": topic.position,
                "title": topic.title,
                "state": state,
                "confirmed_sources": confirmed,
                "proposed_sources": proposed,
                "reason_codes": reason_codes,
                "guidance": {
                    "recommended_source_kinds": ["pdf", "markdown", "plain_text", "link"],
                    "source_intake_url": (
                        f"/sources/intake?enrollment_id={enrollment.id}&topic_id={topic.id}"
                    ),
                },
            }
        )
    provisional = enrollment.topic_state != "canonical" or any(
        topic.state != "canonical" for topic in topics
    )
    denominator = len(topics)
    warning = None
    percentage = (
        None if provisional or denominator == 0 else round(numerator * 100 / denominator, 2)
    )
    if enrollment.archived:
        warning = "Enrollment is archived; archived curriculum is excluded from coverage."
    elif provisional:
        warning = (
            "Topic list is provisional; the displayed denominator is provisional and no "
            "authoritative coverage percentage is available."
        )
    elif denominator == 0:
        warning = "No active canonical topics are available for coverage."
    return {
        "enrollment_id": enrollment.id,
        "disclosure": "source_coverage_not_mastery",
        "numerator": numerator,
        "denominator": denominator,
        "percentage": percentage,
        "provisional": provisional,
        "warning": warning,
        "topics": rows,
    }


async def selectable_evidence_chunks(
    enrollment: ModuleEnrollment,
    topic_id: uuid.UUID,
    source_id: uuid.UUID,
    db: AsyncSession,
) -> list[dict[str, Any]]:
    if enrollment.archived:
        raise WikiBaseError(409, "enrollment_archived", "Archived enrollments cannot be mapped")
    topic_title = await db.scalar(
        select(CurriculumTopic.title).where(
            CurriculumTopic.id == topic_id,
            CurriculumTopic.enrollment_id == enrollment.id,
            CurriculumTopic.archived.is_(False),
        )
    )
    if topic_title is None:
        raise WikiBaseError(400, "invalid_topic_id", "Topic does not belong to this enrollment")
    source = db.sync_session.identity_map.get(db.sync_session.identity_key(Source, source_id))
    if source is None:
        source_state = (
            await db.execute(
                select(Source.user_id, Source.enrollment_id, Source.status).where(
                    Source.id == source_id
                )
            )
        ).one_or_none()
        if source_state is None:
            raise NotFoundError("Source not found")
        source_user_id, source_enrollment_id, source_status = source_state
    else:
        source_user_id = source.user_id
        source_enrollment_id = source.enrollment_id
        source_status = source.status
    if source_user_id != enrollment.user_id:
        raise NotFoundError("Source not found")
    if source_enrollment_id not in {None, enrollment.id}:
        raise WikiBaseError(409, "source_scope_conflict", "Source is outside this enrollment")
    if source_status != SourceStatus.READY:
        raise WikiBaseError(409, "source_not_ready", "Only READY sources have selectable evidence")

    topic_tokens = set(normalized_tokens(topic_title))
    ranked: list[tuple[float, int, int, dict[str, Any]]] = []
    chunk_rows = await db.stream(
        select(
            SourceChunk.id,
            SourceChunk.chunk_index,
            SourceChunk.citation_ref,
            SourceChunk.location_label,
            func.substr(SourceChunk.content, 1, CANDIDATE_SCORING_CHAR_LIMIT * 2).label(
                "scoring_content"
            ),
        )
        .join(Source, Source.id == SourceChunk.source_id)
        .where(
            SourceChunk.source_id == source_id,
            active_source_chunk_predicate(SourceChunk, Source),
        )
        .order_by(SourceChunk.chunk_index, SourceChunk.id)
        .execution_options(yield_per=CANDIDATE_CHUNK_BATCH_SIZE)
    )
    async for batch in chunk_rows.partitions(CANDIDATE_CHUNK_BATCH_SIZE):
        for chunk_id, chunk_index, citation, location, content in batch:
            normalized_content = re.sub(
                r"\s+", " ", content[: CANDIDATE_SCORING_CHAR_LIMIT * 2]
            ).strip()[:CANDIDATE_SCORING_CHAR_LIMIT]
            matched = topic_tokens & set(normalized_tokens(normalized_content))
            relevance = round(
                len(matched) / len(topic_tokens) if topic_tokens else 0.0,
                4,
            )
            candidate = {
                "chunk_id": chunk_id,
                "citation": citation,
                "location": location,
                "excerpt": _excerpt(normalized_content, matched),
                "relevance": relevance,
            }
            entry = (relevance, -chunk_index, -chunk_id.int, candidate)
            if len(ranked) < CANDIDATE_CHUNK_LIMIT:
                heapq.heappush(ranked, entry)
            elif entry[:3] > ranked[0][:3]:
                heapq.heapreplace(ranked, entry)

    ranked.sort(key=lambda item: item[:3], reverse=True)
    return [dict(entry[3], rank=rank) for rank, entry in enumerate(ranked, 1)]


async def candidate_sources(enrollment: ModuleEnrollment, db: AsyncSession) -> list[dict[str, Any]]:
    sources = list(
        (
            await db.execute(
                select(Source)
                .where(
                    Source.user_id == enrollment.user_id,
                    Source.status != SourceStatus.ARCHIVED,
                )
                .order_by(Source.updated_at.desc(), Source.id)
                .limit(100)
            )
        ).scalars()
    )
    result = []
    for source in sources:
        if source.status == SourceStatus.READY:
            state = "ready"
        elif source.status == SourceStatus.FAILED:
            state = "failed"
        else:
            state = "processing"
        if source.enrollment_id == enrollment.id:
            attachment = "enrollment"
        elif source.enrollment_id is None:
            attachment = "unscoped"
        else:
            attachment = "other_enrollment"
        result.append(
            {
                "id": source.id,
                "title": source.title,
                "source_type": source.source_type.value,
                "state": state,
                "import_error": source.import_error,
                "attachment": attachment,
                "eligible": attachment != "other_enrollment",
            }
        )
    return result


async def remove_confirmed_association(
    enrollment: ModuleEnrollment,
    association_id: uuid.UUID,
    user: User,
    db: AsyncSession,
) -> TopicSourceAssociation:
    if enrollment.archived:
        raise WikiBaseError(409, "enrollment_archived", "Archived enrollments cannot be mapped")
    await db.execute(
        select(ModuleEnrollment.id).where(ModuleEnrollment.id == enrollment.id).with_for_update()
    )
    identifiers = (
        await db.execute(
            select(TopicSourceAssociation.topic_id, TopicSourceAssociation.source_id).where(
                TopicSourceAssociation.id == association_id,
                TopicSourceAssociation.enrollment_id == enrollment.id,
            )
        )
    ).one_or_none()
    if identifiers is None:
        raise NotFoundError("Association not found")
    topic = await db.scalar(
        select(CurriculumTopic)
        .where(
            CurriculumTopic.id == identifiers.topic_id,
            CurriculumTopic.enrollment_id == enrollment.id,
            CurriculumTopic.archived.is_(False),
        )
        .with_for_update()
    )
    if topic is None:
        raise WikiBaseError(409, "topic_archived", "Archived topics cannot be mapped")
    source = await db.scalar(
        select(Source)
        .where(Source.id == identifiers.source_id, Source.user_id == user.id)
        .with_for_update()
    )
    if source is None:
        raise NotFoundError("Source not found")
    if source.enrollment_id not in {None, enrollment.id}:
        raise WikiBaseError(409, "source_scope_conflict", "Source is outside this enrollment")
    row = await db.scalar(
        select(TopicSourceAssociation)
        .where(
            TopicSourceAssociation.id == association_id,
            TopicSourceAssociation.enrollment_id == enrollment.id,
        )
        .with_for_update()
    )
    if row is None:
        raise NotFoundError("Association not found")
    if row.status != "confirmed":
        raise WikiBaseError(409, "association_not_confirmed", "Association is not confirmed")
    row.status = "rejected"
    row.reason_code = "confirmed_association_removed"
    row.reviewed_at = datetime.now(UTC)
    row.updated_at = row.reviewed_at
    row.reviewer_id = user.id
    await db.flush()
    return row
