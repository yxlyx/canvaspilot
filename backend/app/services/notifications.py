import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import String, cast, delete, exists, func, literal, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError
from app.models.flashcard import Flashcard, FlashcardAttempt
from app.models.m3 import HealthFinding, MarkedPaper
from app.models.settings import InAppNotification
from app.models.source import Source, SourceStatus
from app.models.user import User
from app.services.preferences import get_preferences_by_user_id


async def upsert_notification(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    kind: str,
    title: str,
    body: str,
    href: str,
    dedupe_key: str,
    expires_at: datetime | None = None,
) -> InAppNotification:
    insert_statement = insert(InAppNotification).values(
        user_id=user_id,
        kind=kind,
        title=title,
        body=body,
        href=href,
        dedupe_key=dedupe_key,
        expires_at=expires_at,
    )
    statement = insert_statement.on_conflict_do_update(
        index_elements=[InAppNotification.user_id, InAppNotification.dedupe_key],
        set_={
            "title": insert_statement.excluded.title,
            "body": insert_statement.excluded.body,
            "href": insert_statement.excluded.href,
            "expires_at": insert_statement.excluded.expires_at,
        },
        where=(
            InAppNotification.title.is_distinct_from(insert_statement.excluded.title)
            | InAppNotification.body.is_distinct_from(insert_statement.excluded.body)
            | InAppNotification.href.is_distinct_from(insert_statement.excluded.href)
            | InAppNotification.expires_at.is_distinct_from(insert_statement.excluded.expires_at)
        ),
    ).returning(InAppNotification.id)
    await db.execute(statement)
    notification = await db.scalar(
        select(InAppNotification).where(
            InAppNotification.user_id == user_id,
            InAppNotification.dedupe_key == dedupe_key,
        )
    )
    if notification is None:
        raise RuntimeError("notification upsert did not return the stored row")
    return notification


async def _upsert_notifications_from_select(db: AsyncSession, rows) -> None:
    insert_statement = insert(InAppNotification).from_select(
        [
            InAppNotification.id,
            InAppNotification.user_id,
            InAppNotification.kind,
            InAppNotification.title,
            InAppNotification.body,
            InAppNotification.href,
            InAppNotification.dedupe_key,
        ],
        rows,
        include_defaults=False,
    )
    await db.execute(
        insert_statement.on_conflict_do_update(
            index_elements=[InAppNotification.user_id, InAppNotification.dedupe_key],
            set_={
                "title": insert_statement.excluded.title,
                "body": insert_statement.excluded.body,
                "href": insert_statement.excluded.href,
            },
            where=(
                InAppNotification.title.is_distinct_from(insert_statement.excluded.title)
                | InAppNotification.body.is_distinct_from(insert_statement.excluded.body)
                | InAppNotification.href.is_distinct_from(insert_statement.excluded.href)
            ),
        )
    )


async def _delete_stale_notifications(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    kind: str,
    key_prefix: str,
    desired_keys: set[str],
) -> None:
    statement = delete(InAppNotification).where(
        InAppNotification.user_id == user_id,
        InAppNotification.kind == kind,
        InAppNotification.dedupe_key.like(f"{key_prefix}%"),
    )
    if desired_keys:
        statement = statement.where(InAppNotification.dedupe_key.not_in(sorted(desired_keys)))
    await db.execute(statement)


async def sync_attention_notifications(user_id: uuid.UUID, db: AsyncSession) -> None:
    preferences = await get_preferences_by_user_id(user_id, db)
    now = datetime.now(UTC)
    today = now.date()
    daily_review_keys: set[str] = set()
    if preferences.reminder_daily_review:
        card_count = await db.scalar(
            select(func.count(Flashcard.id)).where(Flashcard.user_id == user_id)
        )
        attempts = await db.scalar(
            select(func.count(FlashcardAttempt.id)).where(
                FlashcardAttempt.user_id == user_id,
                FlashcardAttempt.created_at >= datetime.combine(today, datetime.min.time(), UTC),
            )
        )
        if card_count and attempts < preferences.daily_review_target:
            remaining = preferences.daily_review_target - attempts
            dedupe_key = f"daily-review:{today.isoformat()}"
            daily_review_keys.add(dedupe_key)
            await upsert_notification(
                db,
                user_id=user_id,
                kind="daily_review",
                title="Your review target is waiting",
                body=f"Review {remaining} more card{'s' if remaining != 1 else ''} today.",
                href="/flashcards",
                dedupe_key=dedupe_key,
                expires_at=datetime.combine(today + timedelta(days=1), datetime.min.time(), UTC),
            )
    await _delete_stale_notifications(
        db,
        user_id=user_id,
        kind="daily_review",
        key_prefix="daily-review:",
        desired_keys=daily_review_keys,
    )

    source_key = func.concat("source-failed:", cast(Source.id, String))
    if preferences.reminder_processing_attention:
        await _upsert_notifications_from_select(
            db,
            select(
                func.gen_random_uuid(),
                Source.user_id,
                literal("processing_attention"),
                literal("A source needs attention"),
                Source.title,
                literal("/sources"),
                source_key,
            )
            .where(Source.user_id == user_id, Source.status == SourceStatus.FAILED)
            .order_by(source_key),
        )
    matching_failed_source = exists(
        select(Source.id).where(
            Source.user_id == user_id,
            Source.status == SourceStatus.FAILED,
            InAppNotification.dedupe_key == source_key,
        )
    )
    await db.execute(
        delete(InAppNotification).where(
            InAppNotification.user_id == user_id,
            InAppNotification.kind == "processing_attention",
            InAppNotification.dedupe_key.like("source-failed:%"),
            ~matching_failed_source if preferences.reminder_processing_attention else literal(True),
        )
    )

    paper_id = cast(MarkedPaper.id, String)
    paper_key = func.concat("paper-review:", paper_id)
    if preferences.reminder_paper_review:
        await _upsert_notifications_from_select(
            db,
            select(
                func.gen_random_uuid(),
                MarkedPaper.user_id,
                literal("paper_review"),
                literal("Marked work is ready to review"),
                MarkedPaper.filename,
                func.concat("/sources/papers/", paper_id),
                paper_key,
            )
            .where(
                MarkedPaper.user_id == user_id,
                MarkedPaper.extraction_status == "pending_review",
            )
            .order_by(paper_key),
        )
    matching_pending_paper = exists(
        select(MarkedPaper.id).where(
            MarkedPaper.user_id == user_id,
            MarkedPaper.extraction_status == "pending_review",
            InAppNotification.dedupe_key == paper_key,
        )
    )
    await db.execute(
        delete(InAppNotification).where(
            InAppNotification.user_id == user_id,
            InAppNotification.kind == "paper_review",
            InAppNotification.dedupe_key.like("paper-review:%"),
            ~matching_pending_paper if preferences.reminder_paper_review else literal(True),
        )
    )

    health_key = func.concat(
        "health-finding:",
        func.md5(
            cast(
                func.jsonb_build_array(
                    HealthFinding.code,
                    HealthFinding.resource_type,
                    HealthFinding.resource_id,
                    HealthFinding.topic,
                ),
                String,
            )
        ),
    )
    active_health_finding = HealthFinding.severity.in_(["warning", "error"])
    if preferences.reminder_health_attention:
        await _upsert_notifications_from_select(
            db,
            select(
                func.gen_random_uuid(),
                HealthFinding.user_id,
                literal("health_attention"),
                literal("Workspace health needs attention"),
                HealthFinding.message,
                func.concat("/sources/health/", cast(HealthFinding.id, String)),
                health_key,
            )
            .where(HealthFinding.user_id == user_id, active_health_finding)
            .distinct(health_key)
            .order_by(
                health_key,
                HealthFinding.created_at.desc(),
                HealthFinding.id.desc(),
            ),
        )
    await db.execute(
        delete(InAppNotification).where(
            InAppNotification.user_id == user_id,
            InAppNotification.kind == "health_attention",
            InAppNotification.dedupe_key.like("health:%"),
        )
    )
    matching_health_finding = exists(
        select(HealthFinding.id).where(
            HealthFinding.user_id == user_id,
            active_health_finding,
            InAppNotification.dedupe_key == health_key,
        )
    )
    await db.execute(
        delete(InAppNotification).where(
            InAppNotification.user_id == user_id,
            InAppNotification.kind == "health_attention",
            InAppNotification.dedupe_key.like("health-finding:%"),
            ~matching_health_finding if preferences.reminder_health_attention else literal(True),
        )
    )


async def list_notifications(
    user: User, db: AsyncSession, unread_only: bool, limit: int
) -> tuple[list[InAppNotification], int]:
    user_id = user.id
    await sync_attention_notifications(user_id, db)
    await db.commit()
    now = datetime.now(UTC)
    base = [
        InAppNotification.user_id == user_id,
        (InAppNotification.expires_at.is_(None) | (InAppNotification.expires_at > now)),
    ]
    statement = select(InAppNotification).where(*base)
    if unread_only:
        statement = statement.where(InAppNotification.read_at.is_(None))
    items = list(
        (
            await db.execute(
                statement.order_by(
                    InAppNotification.created_at.desc(), InAppNotification.id.desc()
                ).limit(limit)
            )
        ).scalars()
    )
    unread_count = await db.scalar(
        select(func.count(InAppNotification.id)).where(*base, InAppNotification.read_at.is_(None))
    )
    return items, int(unread_count or 0)


async def mark_notification_read(
    user: User, notification_id: uuid.UUID, db: AsyncSession
) -> InAppNotification:
    notification = await db.scalar(
        select(InAppNotification).where(
            InAppNotification.id == notification_id,
            InAppNotification.user_id == user.id,
        )
    )
    if notification is None:
        raise NotFoundError("Notification not found")
    notification.read_at = datetime.now(UTC)
    await db.commit()
    await db.refresh(notification)
    return notification


async def mark_all_notifications_read(user: User, db: AsyncSession) -> None:
    await sync_attention_notifications(user.id, db)
    await db.execute(
        update(InAppNotification)
        .where(InAppNotification.user_id == user.id, InAppNotification.read_at.is_(None))
        .values(read_at=datetime.now(UTC))
    )
    await db.commit()
