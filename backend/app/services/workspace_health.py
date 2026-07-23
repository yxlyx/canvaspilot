import difflib
import uuid
from datetime import UTC, datetime, timedelta
from urllib.parse import urlsplit, urlunsplit

from sqlalchemy import delete, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError, WikiBaseError
from app.models.m3 import HealthFinding, SourceChange, WikiRevision
from app.models.source import Source, SourceStatus
from app.models.user import User
from app.models.wiki import WikiPage
from app.services.notifications import sync_attention_notifications

MAX_HISTORY_RESULTS = 100
MAX_HEALTH_RESOURCES = 500
MAX_DIFF_INPUT_CHARS = 1_000_000
MAX_DIFF_OUTPUT_CHARS = 2_000_000
STALE_AFTER = timedelta(days=30)


def revision_diff(before: WikiRevision, after: WikiRevision) -> str:
    if len(before.markdown) + len(after.markdown) > MAX_DIFF_INPUT_CHARS:
        raise WikiBaseError(413, "diff_too_large", "Revision diff input exceeds the limit")
    diff = "".join(
        difflib.unified_diff(
            before.markdown.splitlines(keepends=True),
            after.markdown.splitlines(keepends=True),
            fromfile=f"revision-{before.revision_number}.md",
            tofile=f"revision-{after.revision_number}.md",
        )
    )
    if len(diff) > MAX_DIFF_OUTPUT_CHARS:
        raise WikiBaseError(413, "diff_too_large", "Revision diff output exceeds the limit")
    return diff


def _canonical_url(value: str) -> str:
    try:
        parts = urlsplit(value.strip())
    except ValueError:
        return value.strip().lower()
    try:
        host = (parts.hostname or "").lower()
        port = parts.port
    except ValueError:
        return value.strip().lower()
    if not host:
        return value.strip().lower()
    netloc = host if port in (None, 80, 443) else f"{host}:{port}"
    path = parts.path.rstrip("/") or "/"
    return urlunsplit((parts.scheme.lower(), netloc, path, parts.query, ""))


async def list_revisions(user: User, page_id: uuid.UUID, db: AsyncSession) -> list[WikiRevision]:
    result = await db.execute(
        select(WikiRevision)
        .where(WikiRevision.user_id == user.id, WikiRevision.page_id == page_id)
        .order_by(WikiRevision.revision_number.desc())
        .limit(MAX_HISTORY_RESULTS)
    )
    revisions = list(result.scalars().all())
    if not revisions:
        owned = await db.scalar(
            select(WikiPage.id).where(WikiPage.id == page_id, WikiPage.user_id == user.id)
        )
        if owned is None:
            raise NotFoundError("Wiki page not found")
    return revisions


async def get_revision_diff(
    user: User, page_id: uuid.UUID, from_number: int, to_number: int, db: AsyncSession
) -> str:
    result = await db.execute(
        select(WikiRevision).where(
            WikiRevision.user_id == user.id,
            WikiRevision.page_id == page_id,
            WikiRevision.revision_number.in_([from_number, to_number]),
        )
    )
    revisions = {item.revision_number: item for item in result.scalars()}
    if from_number not in revisions or to_number not in revisions:
        raise NotFoundError("Wiki revision not found")
    return revision_diff(revisions[from_number], revisions[to_number])


def _finding(user_id: uuid.UUID, **values) -> HealthFinding:
    return HealthFinding(user_id=user_id, **values)


def _workspace_status_finding(user_id: uuid.UUID, evaluated_resource_count: int) -> HealthFinding:
    if evaluated_resource_count == 0:
        return _finding(
            user_id,
            code="workspace_not_evaluated",
            severity="info",
            state="unknown",
            resource_type="workspace",
            resource_id=None,
            topic=None,
            message=(
                "Workspace health cannot be evaluated without ready sources or current wiki pages."
            ),
            recommendation=(
                "Add or finish indexing a source, then run workspace health checks again."
            ),
        )
    return _finding(
        user_id,
        code="workspace_healthy",
        severity="info",
        state="healthy",
        resource_type="workspace",
        resource_id=None,
        topic=None,
        message="No workspace health problems were found.",
        recommendation="Continue reviewing sources regularly.",
    )


async def run_health_checks(user: User, db: AsyncSession) -> list[HealthFinding]:
    user_id = user.id
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"health:{user_id}"},
    )
    sources = list(
        (
            await db.execute(
                select(Source)
                .where(
                    Source.user_id == user.id,
                    Source.status != SourceStatus.ARCHIVED,
                )
                .limit(MAX_HEALTH_RESOURCES + 1)
            )
        ).scalars()
    )
    pages = list(
        (
            await db.execute(
                select(WikiPage)
                .where(WikiPage.user_id == user.id, WikiPage.is_current.is_(True))
                .limit(MAX_HEALTH_RESOURCES + 1)
            )
        ).scalars()
    )
    if len(sources) > MAX_HEALTH_RESOURCES or len(pages) > MAX_HEALTH_RESOURCES:
        raise WikiBaseError(
            413, "health_scope_too_large", "Workspace health is limited to 500 resources"
        )
    findings: list[HealthFinding] = []
    now = datetime.now(UTC)

    for page in sorted(pages, key=lambda item: (item.slug, str(item.id))):
        if page.citation_count == 0:
            findings.append(
                _finding(
                    user.id,
                    code="missing_citations",
                    severity="error",
                    state="failed",
                    resource_type="wiki_page",
                    resource_id=page.id,
                    topic=None,
                    message=f"{page.title} has no citations.",
                    recommendation="Recompile this page from a ready cited source.",
                )
            )
        updated_at = (
            page.updated_at.replace(tzinfo=UTC)
            if page.updated_at.tzinfo is None
            else page.updated_at
        )
        if now - updated_at > STALE_AFTER:
            findings.append(
                _finding(
                    user.id,
                    code="stale_page",
                    severity="warning",
                    state="stale",
                    resource_type="wiki_page",
                    resource_id=page.id,
                    topic=None,
                    message=f"{page.title} has not been refreshed in 30 days.",
                    recommendation="Review its sources and recompile the wiki.",
                )
            )

    duplicate_keys: dict[str, list[Source]] = {}
    for source in sources:
        key = _canonical_url(source.source_url)
        if key:
            duplicate_keys.setdefault(key, []).append(source)
        if source.status == SourceStatus.FAILED:
            findings.append(
                _finding(
                    user.id,
                    code="unsupported_or_failed_source",
                    severity="error",
                    state="failed",
                    resource_type="source",
                    resource_id=source.id,
                    topic=None,
                    message=f"{source.title} could not be imported.",
                    recommendation="Use a supported file or correct the import error.",
                )
            )
    for duplicates in duplicate_keys.values():
        if len(duplicates) > 1:
            for source in sorted(duplicates, key=lambda item: str(item.id))[1:]:
                findings.append(
                    _finding(
                        user.id,
                        code="duplicate_source",
                        severity="warning",
                        state="warning",
                        resource_type="source",
                        resource_id=source.id,
                        topic=None,
                        message=f"{source.title} duplicates another source URL.",
                        recommendation="Archive or merge the duplicate source.",
                    )
                )

    covered_sources = {source_id for page in pages for source_id in page.source_ids}
    topics: dict[str, list[Source]] = {}
    for source in sources:
        for topic in source.topic_tags:
            topics.setdefault(topic, []).append(source)
    for topic, topic_sources in sorted(topics.items()):
        if not any(source.id in covered_sources for source in topic_sources):
            findings.append(
                _finding(
                    user.id,
                    code="weak_topic_coverage",
                    severity="warning",
                    state="warning",
                    resource_type="topic",
                    resource_id=None,
                    topic=topic,
                    message=f"{topic} has source evidence but no compiled wiki coverage.",
                    recommendation="Compile a cited wiki page for this topic.",
                )
            )

    if not findings:
        evaluated_resource_count = sum(
            source.status == SourceStatus.READY for source in sources
        ) + len(pages)
        findings.append(_workspace_status_finding(user.id, evaluated_resource_count))
    await db.execute(delete(HealthFinding).where(HealthFinding.user_id == user.id))
    db.add_all(findings)
    await db.flush()
    await sync_attention_notifications(user_id, db)
    return findings


async def list_source_changes(user: User, db: AsyncSession, limit: int) -> list[SourceChange]:
    result = await db.execute(
        select(SourceChange)
        .where(SourceChange.user_id == user.id)
        .order_by(SourceChange.created_at.desc(), SourceChange.id.asc())
        .limit(limit)
    )
    return list(result.scalars())


async def get_finding(user: User, finding_id: uuid.UUID, db: AsyncSession) -> HealthFinding:
    result = await db.execute(
        select(HealthFinding).where(
            HealthFinding.id == finding_id, HealthFinding.user_id == user.id
        )
    )
    finding = result.scalar_one_or_none()
    if finding is None:
        raise NotFoundError("Health finding not found")
    return finding


async def list_findings(user: User, db: AsyncSession, limit: int) -> list[HealthFinding]:
    result = await db.execute(
        select(HealthFinding)
        .where(HealthFinding.user_id == user.id)
        .order_by(HealthFinding.created_at.desc(), HealthFinding.id.asc())
        .limit(limit)
    )
    return list(result.scalars())


async def history_entries(user: User, db: AsyncSession, limit: int) -> list[dict]:
    changes = list(
        (
            await db.execute(
                select(SourceChange)
                .where(SourceChange.user_id == user.id)
                .order_by(SourceChange.created_at.desc())
                .limit(limit)
            )
        ).scalars()
    )
    revisions = list(
        (
            await db.execute(
                select(WikiRevision)
                .where(WikiRevision.user_id == user.id)
                .order_by(WikiRevision.created_at.desc())
                .limit(limit)
            )
        ).scalars()
    )
    entries = [
        {
            "id": item.id,
            "entry_type": "source_change",
            "resource_id": item.source_id,
            "summary": item.change_type,
            "created_at": item.created_at,
        }
        for item in changes
    ] + [
        {
            "id": item.id,
            "entry_type": "wiki_revision",
            "resource_id": item.page_id,
            "summary": item.change_summary or f"Revision {item.revision_number}",
            "created_at": item.created_at,
        }
        for item in revisions
    ]
    return sorted(
        entries,
        key=lambda item: (item["created_at"], str(item["id"])),
        reverse=True,
    )[:limit]
