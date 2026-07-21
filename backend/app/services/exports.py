import json
import uuid
import zipfile
from dataclasses import dataclass
from io import BytesIO

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.exceptions import NotFoundError, WikiBaseError
from app.models.user import User
from app.models.wiki import WikiPage

MAX_EXPORT_PAGES = 100
MAX_EXPORT_BYTES = 10 * 1024 * 1024


@dataclass(frozen=True)
class ExportFile:
    content: bytes
    filename: str
    media_type: str


def _safe_filename(slug: str) -> str:
    cleaned = "".join(char for char in slug.lower() if char.isalnum() or char in "-_").strip("-_")
    return f"{cleaned or 'wiki-page'}.md"


def canonical_markdown(page: WikiPage) -> str:
    source_lines = (
        ["source_ids:", *[f'  - "{source_id}"' for source_id in page.source_ids]]
        if page.source_ids
        else ["source_ids: []"]
    )
    backlink_lines = (
        [
            "backlinks:",
            *[f"  - {json.dumps(slug, ensure_ascii=False)}" for slug in page.backlinks],
        ]
        if page.backlinks
        else ["backlinks: []"]
    )
    metadata = [
        "---",
        "canvaspilot_export: 1",
        f'id: "{page.id}"',
        f'slug: "{page.slug}"',
        f"title: {json.dumps(page.title, ensure_ascii=False)}",
        f'updated_at: "{page.updated_at.isoformat()}"',
        *source_lines,
        f"citation_count: {page.citation_count}",
        *backlink_lines,
        "---",
        "",
    ]
    return "\n".join(metadata) + page.markdown.rstrip() + "\n"


async def _owned_pages(
    user: User, db: AsyncSession, page_ids: list[uuid.UUID] | None
) -> list[WikiPage]:
    statement = (
        select(WikiPage)
        .options(selectinload(WikiPage.citations))
        .where(WikiPage.user_id == user.id, WikiPage.is_current.is_(True))
        .order_by(WikiPage.slug.asc(), WikiPage.id.asc())
        .limit(MAX_EXPORT_PAGES + 1)
    )
    if page_ids is not None:
        statement = statement.where(WikiPage.id.in_(page_ids))
    pages = list((await db.execute(statement)).scalars().unique().all())
    if page_ids is not None and {page.id for page in pages} != set(page_ids):
        raise NotFoundError("One or more wiki pages were not found")
    if len(pages) > MAX_EXPORT_PAGES:
        raise WikiBaseError(413, "export_too_large", "Export is limited to 100 pages")
    if not pages:
        raise NotFoundError("No wiki pages are available to export")
    return pages


async def export_page(user: User, slug: str, db: AsyncSession) -> ExportFile:
    result = await db.execute(
        select(WikiPage).where(
            WikiPage.user_id == user.id,
            WikiPage.slug == slug,
            WikiPage.is_current.is_(True),
        )
    )
    page = result.scalar_one_or_none()
    if page is None:
        raise NotFoundError("Wiki page not found")
    content = canonical_markdown(page).encode()
    if len(content) > MAX_EXPORT_BYTES:
        raise WikiBaseError(413, "export_too_large", "Export exceeds the 10 MiB limit")
    return ExportFile(content, _safe_filename(page.slug), "text/markdown; charset=utf-8")


async def export_workspace(
    user: User, db: AsyncSession, page_ids: list[uuid.UUID] | None = None
) -> ExportFile:
    pages = await _owned_pages(user, db, page_ids)
    output = BytesIO()
    total_bytes = 0
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as archive:
        for page in pages:
            content = canonical_markdown(page).encode()
            total_bytes += len(content)
            if total_bytes > MAX_EXPORT_BYTES:
                raise WikiBaseError(413, "export_too_large", "Archive exceeds the 10 MiB limit")
            info = zipfile.ZipInfo(_safe_filename(page.slug), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            archive.writestr(info, content)
            if output.tell() > MAX_EXPORT_BYTES:
                raise WikiBaseError(413, "export_too_large", "Archive exceeds the 10 MiB limit")
    content = output.getvalue()
    if len(content) > MAX_EXPORT_BYTES:
        raise WikiBaseError(413, "export_too_large", "Archive exceeds the 10 MiB limit")
    return ExportFile(content, "workspace-wiki.zip", "application/zip")
