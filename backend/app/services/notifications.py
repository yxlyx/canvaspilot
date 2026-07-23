import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, select, update
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


async def sync_attention_notifications(user_id: uuid.UUID, db: AsyncSession) -> None:
    preferences = await get_preferences_by_user_id(user_id, db)
    now = datetime.now(UTC)
    today = now.date()
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
            await upsert_notification(
                db,
                user_id=user_id,
                kind="daily_review",
                title="Your review target is waiting",
                body=f"Review {remaining} more card{'s' if remaining != 1 else ''} today.",
                href="/flashcards",
                dedupe_key=f"daily-review:{today.isoformat()}",
                expires_at=datetime.combine(today + timedelta(days=1), datetime.min.time(), UTC),
            )
    if preferences.reminder_processing_attention:
        failed_sources = list(
            (
                await db.execute(
                    select(Source).where(
                        Source.user_id == user_id, Source.status == SourceStatus.FAILED
                    )
                )
            ).scalars()
        )
        for source in failed_sources:
            await upsert_notification(
                db,
                user_id=user_id,
                kind="processing_attention",
                title="A source needs attention",
                body=source.title,
                href="/sources",
                dedupe_key=f"source-failed:{source.id}",
            )
    if preferences.reminder_paper_review:
        pending_papers = list(
            (
                await db.execute(
                    select(MarkedPaper).where(
                        MarkedPaper.user_id == user_id,
                        MarkedPaper.extraction_status == "pending_review",
                    )
                )
            ).scalars()
        )
        for paper in pending_papers:
            await upsert_notification(
                db,
                user_id=user_id,
                kind="paper_review",
                title="Marked work is ready to review",
                body=paper.filename,
                href=f"/sources/papers/{paper.id}",
                dedupe_key=f"paper-review:{paper.id}",
            )
    findings = list(
        (
            await db.execute(
                select(HealthFinding).where(
                    HealthFinding.user_id == user_id,
                    HealthFinding.severity.in_(["warning", "error"]),
                )
            )
        ).scalars()
    )
    health_keys = [
        (
            f"health-finding:{finding.code}:{finding.resource_type}:"
            f"{finding.resource_id or '-'}:{finding.topic or '-'}"
        )
        for finding in findings
    ]
    await db.execute(
        delete(InAppNotification).where(
            InAppNotification.user_id == user_id,
            InAppNotification.kind == "health_attention",
            InAppNotification.dedupe_key.like("health:%"),
        )
    )
    stale_health = delete(InAppNotification).where(
        InAppNotification.user_id == user_id,
        InAppNotification.kind == "health_attention",
        InAppNotification.dedupe_key.like("health-finding:%"),
    )
    if health_keys:
        stale_health = stale_health.where(InAppNotification.dedupe_key.not_in(health_keys))
    await db.execute(stale_health)
    if preferences.reminder_health_attention:
        for finding in findings:
            dedupe_key = (
                f"health-finding:{finding.code}:{finding.resource_type}:"
                f"{finding.resource_id or '-'}:{finding.topic or '-'}"
            )
            await upsert_notification(
                db,
                user_id=user_id,
                kind="health_attention",
                title="Workspace health needs attention",
                body=finding.message,
                href=f"/sources/health/{finding.id}",
                dedupe_key=dedupe_key,
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
    await db.execute(
        update(InAppNotification)
        .where(InAppNotification.user_id == user.id, InAppNotification.read_at.is_(None))
        .values(read_at=datetime.now(UTC))
    )
    await db.commit()
