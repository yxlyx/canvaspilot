from collections import defaultdict
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.flashcard import Flashcard, FlashcardAttempt
from app.models.m3 import MarkedPaper, MarkedPaperQuestion
from app.models.source import Source, SourceStatus
from app.models.user import User
from app.schemas.m3 import MeterSignal, TopicMeterResponse

MAX_METER_TOPICS = 100
MAX_EVIDENCE_ROWS = 2_000
STALE_DAYS = 30


@dataclass(frozen=True)
class TopicEvidence:
    source_count: int = 0
    correct: int = 0
    attempts: int = 0
    confidence_total: float = 0
    confidence_count: int = 0
    marked_score_total: float = 0
    marked_score_count: int = 0
    latest_at: datetime | None = None


def calculate_topic_meter(topic: str, evidence: TopicEvidence, now: datetime) -> TopicMeterResponse:
    flashcard_recall = evidence.correct / evidence.attempts if evidence.attempts else None
    marked_paper_score = (
        evidence.marked_score_total / evidence.marked_score_count
        if evidence.marked_score_count
        else None
    )
    confidence = (
        evidence.confidence_total / evidence.confidence_count if evidence.confidence_count else None
    )
    age_days = (now - evidence.latest_at).days if evidence.latest_at else None
    stale = age_days is not None and age_days > STALE_DAYS
    evidence_count = evidence.source_count + evidence.attempts + evidence.marked_score_count

    return TopicMeterResponse(
        topic=topic,
        estimated_completion=None,
        evidence_confidence=None,
        evidence_count=evidence_count,
        state="stale" if stale else "uncertain",
        stale=stale,
        signals=[
            MeterSignal(
                name="source_count",
                value=float(evidence.source_count) if evidence.source_count else None,
                evidence_count=evidence.source_count,
            ),
            MeterSignal(
                name="flashcard_recall",
                value=flashcard_recall,
                evidence_count=evidence.attempts,
            ),
            MeterSignal(
                name="marked_paper_score",
                value=marked_paper_score,
                evidence_count=evidence.marked_score_count,
            ),
            MeterSignal(
                name="self_reported_confidence",
                value=confidence,
                evidence_count=evidence.confidence_count,
            ),
        ],
        recommendation=(
            "Use enrollment-scoped source coverage and recall metrics; "
            "this legacy view is non-authoritative."
        ),
        reason_code="legacy_meter_non_authoritative",
    )


async def topic_meters(user: User, db: AsyncSession) -> list[TopicMeterResponse]:
    mutable: dict[str, dict] = defaultdict(
        lambda: {
            "source_count": 0,
            "correct": 0,
            "attempts": 0,
            "confidence_total": 0.0,
            "confidence_count": 0,
            "marked_score_total": 0.0,
            "marked_score_count": 0,
            "latest_at": None,
        }
    )
    sources = list(
        (
            await db.execute(
                select(Source)
                .where(Source.user_id == user.id, Source.status == SourceStatus.READY)
                .order_by(Source.id)
                .limit(MAX_EVIDENCE_ROWS)
            )
        ).scalars()
    )
    for source in sources:
        for topic in source.topic_tags[:MAX_METER_TOPICS]:
            mutable[topic]["source_count"] += 1

    attempts = (
        await db.execute(
            select(FlashcardAttempt, Flashcard)
            .join(Flashcard, FlashcardAttempt.card_id == Flashcard.id)
            .where(FlashcardAttempt.user_id == user.id, Flashcard.user_id == user.id)
            .order_by(FlashcardAttempt.created_at.desc())
            .limit(MAX_EVIDENCE_ROWS)
        )
    ).all()
    for attempt, card in attempts:
        values = mutable[card.topic_tag]
        values["attempts"] += 1
        values["correct"] += int(attempt.is_correct)
        if attempt.confidence is not None:
            values["confidence_total"] += attempt.confidence / 5
            values["confidence_count"] += 1
        if values["latest_at"] is None or attempt.created_at > values["latest_at"]:
            values["latest_at"] = attempt.created_at

    questions = (
        await db.execute(
            select(MarkedPaperQuestion, MarkedPaper)
            .join(MarkedPaper, MarkedPaperQuestion.paper_id == MarkedPaper.id)
            .where(MarkedPaper.user_id == user.id, MarkedPaperQuestion.reviewed.is_(True))
            .order_by(
                MarkedPaperQuestion.reviewed_at.desc(),
                MarkedPaperQuestion.id.asc(),
            )
            .limit(MAX_EVIDENCE_ROWS)
        )
    ).all()
    for question, _paper in questions:
        if (
            question.awarded_marks is None
            or question.available_marks is None
            or question.reviewed_at is None
        ):
            continue
        values = mutable[question.topic_tag]
        values["marked_score_total"] += min(question.awarded_marks / question.available_marks, 1)
        values["marked_score_count"] += 1
        values["confidence_total"] += question.confidence
        values["confidence_count"] += 1
        if values["latest_at"] is None or question.reviewed_at > values["latest_at"]:
            values["latest_at"] = question.reviewed_at

    now = datetime.now(UTC)
    meters = [
        calculate_topic_meter(topic, TopicEvidence(**values), now)
        for topic, values in sorted(mutable.items())[:MAX_METER_TOPICS]
    ]
    return sorted(
        meters,
        key=lambda meter: (
            meter.estimated_completion is not None,
            meter.estimated_completion if meter.estimated_completion is not None else -1,
            meter.topic,
        ),
    )
