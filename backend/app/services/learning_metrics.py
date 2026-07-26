import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import and_, case, distinct, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.curriculum import CurriculumTopic, ModuleEnrollment
from app.models.flashcard import Flashcard, FlashcardAttempt, FlashcardDeck
from app.models.m3 import SourceChange
from app.models.source import Source
from app.services.curriculum_coverage import coverage_dashboard

ROLLING_WINDOW_DAYS = 30
MINIMUM_TOPIC_ATTEMPTS = 3
MINIMUM_OVERALL_ATTEMPTS = 5


def _reason_and_warning(
    window_attempts: int,
    historical_attempts: int,
    minimum_attempts: int,
) -> tuple[str | None, str | None]:
    if historical_attempts == 0:
        return "no_attempts", "No approved-card recall evidence is available."
    if window_attempts == 0:
        return (
            "stale_attempts",
            "Recall evidence exists, but it is older than the freshness cutoff.",
        )
    if window_attempts < minimum_attempts:
        return (
            "insufficient_attempts",
            f"At least {minimum_attempts} recent attempts are required for a recall percentage.",
        )
    return None, None


def _attempt_scope(user_id: uuid.UUID, enrollment_id: uuid.UUID, window_end: datetime):
    return (
        FlashcardAttempt.user_id == user_id,
        FlashcardDeck.user_id == user_id,
        Flashcard.user_id == user_id,
        Flashcard.deck_id == FlashcardAttempt.deck_id,
        FlashcardDeck.enrollment_id == enrollment_id,
        FlashcardDeck.lifecycle.in_(["approved", "retired"]),
        Flashcard.approved.is_(True),
        FlashcardAttempt.created_at <= window_end,
        or_(
            FlashcardDeck.approved_at.is_(None),
            FlashcardAttempt.created_at >= FlashcardDeck.approved_at,
        ),
        or_(
            FlashcardDeck.retired_at.is_(None),
            FlashcardAttempt.created_at <= FlashcardDeck.retired_at,
        ),
    )


async def _source_coverage(
    enrollment: ModuleEnrollment,
    topics: list[CurriculumTopic],
    db: AsyncSession,
) -> dict[str, Any]:
    dashboard = await coverage_dashboard(enrollment, db)
    rows_by_id = {row["topic_id"]: row for row in dashboard["topics"]}
    classified: dict[str, list[dict[str, Any]]] = {
        "covered": [],
        "missing": [],
        "review": [],
        "stale": [],
    }
    numerator = 0
    for topic in topics:
        row = rows_by_id.get(topic.id)
        confirmed = row["confirmed_sources"] if row else []
        proposed = row["proposed_sources"] if row else []
        current_confirmed = [item for item in confirmed if not item["stale"]]
        stale_confirmed = [item for item in confirmed if item["stale"]]
        current_proposed = [item for item in proposed if not item["stale"]]
        stale_proposed = [item for item in proposed if item["stale"]]
        if current_confirmed:
            state = "covered"
            reason_codes: list[str] = []
            numerator += 1
        elif stale_confirmed:
            state = "stale"
            reason_codes = sorted(
                {item["stale_reason"] or "association_stale" for item in stale_confirmed}
            )
        elif current_proposed:
            state = "review"
            reason_codes = ["proposal_requires_review"]
        elif stale_proposed:
            state = "stale"
            reason_codes = sorted(
                {item["stale_reason"] or "association_stale" for item in stale_proposed}
            )
        else:
            state = "missing"
            reason_codes = row["reason_codes"] if row else ["no_matching_evidence"]
        evidence = sorted(
            confirmed + proposed,
            key=lambda item: (str(item["source_id"]), str(item["id"])),
        )
        metric = {
            "topic_id": topic.id,
            "position": topic.position,
            "title": topic.title,
            "state": state,
            "reason_codes": reason_codes,
            "evidence_links": [
                {
                    "association_id": item["id"],
                    "source_id": item["source_id"],
                    "source_title": item["source_title"],
                    "status": item["status"],
                    "stale": item["stale"],
                    "stale_reason": item["stale_reason"],
                    "evidence": item["evidence"],
                }
                for item in evidence
            ],
        }
        classified[state].append(metric)

    authoritative = (
        not enrollment.archived
        and enrollment.topic_state == "canonical"
        and all(topic.state == "canonical" for topic in topics)
    )
    denominator = None if enrollment.archived else len(topics)
    if enrollment.archived:
        reason_code = "enrollment_archived"
        warning = "Archived enrollments do not have an active source-coverage denominator."
    elif not authoritative:
        reason_code = "provisional_curriculum"
        warning = "The curriculum is provisional; no authoritative coverage percentage is shown."
    elif not topics:
        reason_code = "no_topics"
        warning = "No active canonical topics are available for source coverage."
    else:
        reason_code = warning = None
    percentage = (
        round(numerator * 100 / denominator, 2)
        if authoritative and denominator is not None and denominator > 0
        else None
    )
    return {
        "authoritative": authoritative,
        "numerator": numerator,
        "denominator": denominator,
        "percentage": percentage,
        "reason_code": reason_code,
        "warning": warning,
        "covered_topics": classified["covered"],
        "missing_topics": classified["missing"],
        "review_topics": classified["review"],
        "stale_topics": classified["stale"],
    }


async def enrollment_learning_metrics(
    enrollment: ModuleEnrollment,
    db: AsyncSession,
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    window_end = now or datetime.now(UTC)
    window_start = window_end - timedelta(days=ROLLING_WINDOW_DAYS)
    active_topics = list(
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
        active_topics = []
    topics = [topic for topic in active_topics if topic.state == "canonical"]
    topic_ids = [topic.id for topic in topics]
    provisional_curriculum = enrollment.topic_state != "canonical" or any(
        topic.state != "canonical" for topic in active_topics
    )
    coverage_topics = active_topics if provisional_curriculum else topics
    coverage = await _source_coverage(enrollment, coverage_topics, db)

    per_topic: dict[uuid.UUID, Any] = {}
    if topic_ids:
        rows = (
            await db.execute(
                select(
                    CurriculumTopic.id,
                    func.count(FlashcardAttempt.id)
                    .filter(FlashcardAttempt.created_at >= window_start)
                    .label("attempt_count"),
                    func.coalesce(
                        func.sum(
                            case(
                                (
                                    and_(
                                        FlashcardAttempt.created_at >= window_start,
                                        FlashcardAttempt.is_correct.is_(True),
                                    ),
                                    1,
                                ),
                                else_=0,
                            )
                        ),
                        0,
                    ).label("correct_attempts"),
                    func.count(FlashcardAttempt.id).label("historical_attempts"),
                    func.max(FlashcardAttempt.created_at).label("last_evidence_at"),
                )
                .select_from(CurriculumTopic)
                .join(Flashcard, Flashcard.topic_ids.any(CurriculumTopic.id))
                .join(FlashcardAttempt, FlashcardAttempt.card_id == Flashcard.id)
                .join(FlashcardDeck, FlashcardDeck.id == FlashcardAttempt.deck_id)
                .where(
                    CurriculumTopic.id.in_(topic_ids),
                    *_attempt_scope(enrollment.user_id, enrollment.id, window_end),
                )
                .group_by(CurriculumTopic.id)
            )
        ).all()
        per_topic = {row.id: row for row in rows}

    topic_metrics = []
    for topic in topics:
        row = per_topic.get(topic.id)
        attempts = int(row.attempt_count) if row else 0
        correct = int(row.correct_attempts) if row else 0
        historical = int(row.historical_attempts) if row else 0
        reason_code, warning = _reason_and_warning(attempts, historical, MINIMUM_TOPIC_ATTEMPTS)
        topic_metrics.append(
            {
                "topic_id": topic.id,
                "position": topic.position,
                "title": topic.title,
                "correct_attempts": correct,
                "attempt_count": attempts,
                "percentage": round(correct * 100 / attempts, 2) if reason_code is None else None,
                "last_evidence_at": row.last_evidence_at if row else None,
                "reason_code": reason_code,
                "warning": warning,
            }
        )

    overall_attempts = overall_correct = historical_attempts = 0
    last_evidence_at = None
    if topic_ids:
        overall = (
            await db.execute(
                select(
                    func.count(distinct(FlashcardAttempt.id))
                    .filter(FlashcardAttempt.created_at >= window_start)
                    .label("attempt_count"),
                    func.count(distinct(FlashcardAttempt.id))
                    .filter(
                        FlashcardAttempt.created_at >= window_start,
                        FlashcardAttempt.is_correct.is_(True),
                    )
                    .label("correct_attempts"),
                    func.count(distinct(FlashcardAttempt.id)).label("historical_attempts"),
                    func.max(FlashcardAttempt.created_at).label("last_evidence_at"),
                )
                .select_from(FlashcardAttempt)
                .join(Flashcard, Flashcard.id == FlashcardAttempt.card_id)
                .join(FlashcardDeck, FlashcardDeck.id == FlashcardAttempt.deck_id)
                .where(
                    Flashcard.topic_ids.overlap(topic_ids),
                    *_attempt_scope(enrollment.user_id, enrollment.id, window_end),
                )
            )
        ).one()
        overall_attempts = int(overall.attempt_count)
        overall_correct = int(overall.correct_attempts)
        historical_attempts = int(overall.historical_attempts)
        last_evidence_at = overall.last_evidence_at

    if enrollment.archived:
        recall_reason = "enrollment_archived"
        recall_warning = "Archived enrollments are excluded from active recall measurement."
    elif provisional_curriculum:
        recall_reason = "provisional_curriculum"
        recall_warning = "The curriculum is provisional; canonical-topic recall is unavailable."
    elif not topics:
        recall_reason = "no_topics"
        recall_warning = "No active canonical topics are available for recall measurement."
    else:
        recall_reason, recall_warning = _reason_and_warning(
            overall_attempts, historical_attempts, MINIMUM_OVERALL_ATTEMPTS
        )
    recall = {
        "correct_attempts": overall_correct,
        "attempt_count": overall_attempts,
        "percentage": (
            round(overall_correct * 100 / overall_attempts, 2) if recall_reason is None else None
        ),
        "last_evidence_at": last_evidence_at,
        "reason_code": recall_reason,
        "warning": recall_warning,
        "topics": topic_metrics,
    }

    source_uploads = await db.scalar(
        select(func.count(Source.id)).where(
            Source.user_id == enrollment.user_id,
            Source.enrollment_id == enrollment.id,
            Source.created_at >= window_start,
            Source.created_at <= window_end,
        )
    )
    source_changes = await db.scalar(
        select(func.count(SourceChange.id))
        .join(Source, Source.id == SourceChange.source_id)
        .where(
            SourceChange.user_id == enrollment.user_id,
            Source.user_id == enrollment.user_id,
            Source.enrollment_id == enrollment.id,
            SourceChange.created_at >= window_start,
            SourceChange.created_at <= window_end,
        )
    )
    activity_attempts = (
        await db.execute(
            select(
                func.count(distinct(FlashcardAttempt.id)).label("attempt_count"),
                func.count(distinct(FlashcardAttempt.card_id)).label("cards_reviewed"),
            )
            .select_from(FlashcardAttempt)
            .join(Flashcard, Flashcard.id == FlashcardAttempt.card_id)
            .join(FlashcardDeck, FlashcardDeck.id == FlashcardAttempt.deck_id)
            .where(
                FlashcardAttempt.created_at >= window_start,
                *_attempt_scope(enrollment.user_id, enrollment.id, window_end),
            )
        )
    ).one()
    activity = {
        "attempt_count": int(activity_attempts.attempt_count),
        "cards_reviewed": int(activity_attempts.cards_reviewed),
        "session_count": None,
        "source_uploads": int(source_uploads or 0),
        "source_changes": int(source_changes or 0),
    }
    return {
        "enrollment_id": enrollment.id,
        "source_coverage": coverage,
        "recall": recall,
        "activity": activity,
        "methodology": {
            "coverage_formula": (
                "non-stale confirmed topics / displayed active topics; the authoritative "
                "denominator contains canonical topics only and proposals never count"
            ),
            "recall_formula": (
                "unique correct approved-card attempts / unique approved-card attempts in the "
                "rolling UTC window; overall is weighted by attempts"
            ),
            "activity_formula": (
                "independent event counts in the same rolling UTC window; flashcard activity "
                "includes approved enrollment-deck cards regardless of topic assignment"
            ),
            "window_start": window_start,
            "window_end": window_end,
            "rolling_window_days": ROLLING_WINDOW_DAYS,
            "minimum_attempts_per_topic": MINIMUM_TOPIC_ATTEMPTS,
            "minimum_attempts_overall": MINIMUM_OVERALL_ATTEMPTS,
            "freshness_cutoff": window_start,
            "rating_semantics": {"Again": False, "Hard": True, "Good": True, "Easy": True},
            "exclusions": [
                "proposed, stale, unowned, out-of-scope, non-ready, and non-current "
                "source evidence",
                "draft, archived, unapproved-card, future, and post-retirement attempts",
                "attempts without a matching stable canonical topic ID",
                "session count is null because study sessions are not persisted",
            ],
            "disclosures": [
                "source_coverage_not_mastery",
                "self_reported_recall_not_mastery",
            ],
        },
    }
