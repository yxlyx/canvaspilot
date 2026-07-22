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
    source_value = min(evidence.source_count / 2, 1.0) if evidence.source_count else None
    performance_values: list[tuple[float, int]] = []
    if evidence.attempts:
        performance_values.append((evidence.correct / evidence.attempts, evidence.attempts))
    if evidence.marked_score_count:
        performance_values.append(
            (evidence.marked_score_total / evidence.marked_score_count, evidence.marked_score_count)
        )
    performance = (
        sum(value * count for value, count in performance_values)
        / sum(count for _, count in performance_values)
        if performance_values
        else None
    )
    confidence = (
        evidence.confidence_total / evidence.confidence_count if evidence.confidence_count else None
    )
    age_days = (now - evidence.latest_at).days if evidence.latest_at else None
    recency = max(0.0, 1 - age_days / 60) if age_days is not None else None
    stale = age_days is not None and age_days > STALE_DAYS
    evidence_count = evidence.source_count + evidence.attempts + evidence.marked_score_count
    signal_values = [source_value, performance, confidence, recency]
    available = [value for value in signal_values if value is not None]
    evidence_confidence = min(1.0, evidence_count / 8) * (len(available) / 4)

    estimated: float | None = None
    if len(available) >= 2 and evidence_count >= 2:
        weighted = [
            (source_value, 0.25),
            (performance, 0.45),
            (confidence, 0.15),
            (recency, 0.15),
        ]
        denominator = sum(weight for value, weight in weighted if value is not None)
        estimated = round(
            100
            * sum(value * weight for value, weight in weighted if value is not None)
            / denominator,
            1,
        )

    if estimated is None:
        state = "uncertain"
        recommendation = "Add source and reviewed practice evidence before estimating completion."
    elif stale:
        state = "stale"
        recommendation = "Refresh this stale topic with a cited review and a new flashcard attempt."
    elif estimated < 60:
        state = "measured"
        recommendation = "Review the cited wiki page, then retry weak flashcards for this topic."
    else:
        state = "measured"
        recommendation = "Maintain this topic with spaced review and recent cited practice."

    return TopicMeterResponse(
        topic=topic,
        estimated_completion=estimated,
        evidence_confidence=round(evidence_confidence, 3),
        evidence_count=evidence_count,
        state=state,
        stale=stale,
        signals=[
            MeterSignal(
                name="source_coverage",
                value=source_value,
                evidence_count=evidence.source_count,
            ),
            MeterSignal(
                name="practice_performance",
                value=performance,
                evidence_count=evidence.attempts + evidence.marked_score_count,
            ),
            MeterSignal(
                name="self_confidence",
                value=confidence,
                evidence_count=evidence.confidence_count,
            ),
            MeterSignal(
                name="recency", value=recency, evidence_count=1 if evidence.latest_at else 0
            ),
        ],
        recommendation=recommendation,
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
            .where(FlashcardAttempt.user_id == user.id)
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
