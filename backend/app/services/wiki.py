import re
import uuid
from dataclasses import dataclass, field

from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.exceptions import NotFoundError, WikiBaseError
from app.models.m3 import WikiRevision
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.models.wiki import WikiCitation, WikiPage


@dataclass
class CitationDraft:
    citation_key: str
    citation_ref: str
    source_id: uuid.UUID
    source_chunk_id: uuid.UUID | None
    source_title: str
    location_label: str
    chunk_index: int | None
    snippet: str


@dataclass
class PageDraft:
    title: str
    slug: str
    summary: str
    source_ids: list[uuid.UUID]
    topic_tags: list[str]
    sections: list[str]
    citations: list[CitationDraft]
    backlinks: list[str] = field(default_factory=list)


_slug_re = re.compile(r"[^a-z0-9]+")
_wiki_link_re = re.compile(r"\[\[([^\]]+)\]\]")
MAX_WIKI_PAGES = 99
MAX_WIKI_CONTENT_CHARS = 5_000_000


def slugify(value: str) -> str:
    slug = _slug_re.sub("-", value.lower()).strip("-")
    return slug or "page"


def citation_marker(citation_key: str) -> str:
    return f"[^{citation_key}]"


def format_citation_reference(citation: CitationDraft) -> str:
    location = f", {citation.location_label}" if citation.location_label else ""
    chunk = f", chunk {citation.chunk_index + 1}" if citation.chunk_index is not None else ""
    return (
        f"[^{citation.citation_key}]: {citation.citation_ref} "
        f"({citation.source_title}{location}{chunk})"
    )


def render_section(heading: str, content: str, citation_key: str) -> str:
    clean_heading = heading.strip() or "Section"
    clean_content = content.strip()
    return f"## {clean_heading}\n\n{clean_content} {citation_marker(citation_key)}"


def _first_sentence(value: str, limit: int = 180) -> str:
    compact = " ".join(value.split())
    if not compact:
        return ""
    sentence_end = compact.find(". ")
    if 0 <= sentence_end <= limit:
        return compact[: sentence_end + 1]
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1].rstrip() + "…"


def _unique_slug(title: str, used_slugs: set[str]) -> str:
    base_slug = slugify(title)
    if base_slug == "index":
        base_slug = "index-source"
    slug = base_slug
    suffix = 2
    while slug in used_slugs:
        slug = f"{base_slug}-{suffix}"
        suffix += 1
    used_slugs.add(slug)
    return slug


def _chunk_heading(chunk: SourceChunk) -> str:
    if chunk.location_label:
        return chunk.location_label
    return f"Section {chunk.chunk_index + 1}"


def _citation_from_chunk(source: Source, chunk: SourceChunk, citation_index: int) -> CitationDraft:
    return CitationDraft(
        citation_key=f"c{citation_index}",
        citation_ref=chunk.citation_ref,
        source_id=source.id,
        source_chunk_id=chunk.id,
        source_title=source.title,
        location_label=chunk.location_label,
        chunk_index=chunk.chunk_index,
        snippet=_first_sentence(chunk.content),
    )


def _citation_from_source(source: Source) -> CitationDraft:
    return CitationDraft(
        citation_key="c1",
        citation_ref=source.citation_label,
        source_id=source.id,
        source_chunk_id=None,
        source_title=source.title,
        location_label="",
        chunk_index=None,
        snippet=source.source_url or source.title,
    )


def build_source_page_draft(source: Source, slug: str) -> PageDraft:
    chunks = sorted(source.chunks, key=lambda chunk: chunk.chunk_index)
    sections: list[str] = []
    citations: list[CitationDraft] = []

    if chunks:
        for index, chunk in enumerate(chunks, 1):
            citation = _citation_from_chunk(source, chunk, index)
            citations.append(citation)
            sections.append(
                render_section(_chunk_heading(chunk), chunk.content, citation.citation_key)
            )
    else:
        citation = _citation_from_source(source)
        citations.append(citation)
        description = (
            source.source_url or "This source has metadata but no imported text chunks yet."
        )
        sections.append(render_section("Source record", description, citation.citation_key))

    summary = _first_sentence(chunks[0].content if chunks else source.source_url or source.title)
    return PageDraft(
        title=source.title,
        slug=slug,
        summary=summary,
        source_ids=[source.id],
        topic_tags=list(source.topic_tags or []),
        sections=sections,
        citations=citations,
    )


def build_backlink_map(pages: list[PageDraft]) -> dict[str, list[str]]:
    backlink_map: dict[str, set[str]] = {page.slug: set() for page in pages}
    title_to_slug = {page.title.lower(): page.slug for page in pages}
    slug_lookup = {page.slug for page in pages}

    for page in pages:
        page_topics = set(page.topic_tags)
        page_text = "\n".join(page.sections).lower()
        for other in pages:
            if other.slug == page.slug:
                continue
            shared_topics = page_topics.intersection(other.topic_tags)
            explicit_links = {
                title_to_slug.get(match.strip().lower(), slugify(match.strip()))
                for match in _wiki_link_re.findall(page_text)
            }
            explicit_wiki_link = other.slug in explicit_links.intersection(slug_lookup)
            if shared_topics or explicit_wiki_link:
                backlink_map[page.slug].add(other.slug)
                backlink_map[other.slug].add(page.slug)

    return {slug: sorted(links) for slug, links in backlink_map.items()}


def render_page_markdown(page: PageDraft, pages_by_slug: dict[str, PageDraft]) -> str:
    parts = [f"# {page.title}"]
    if page.summary:
        parts.append(f"> {page.summary}")
    if page.topic_tags:
        parts.append("Topics: " + ", ".join(f"`{tag}`" for tag in page.topic_tags))

    parts.extend(page.sections)

    if page.backlinks:
        links = [
            f"- [[{pages_by_slug[slug].title}]]" for slug in page.backlinks if slug in pages_by_slug
        ]
        if links:
            parts.append("## Backlinks\n\n" + "\n".join(links))

    references = [format_citation_reference(citation) for citation in page.citations]
    if references:
        parts.append("## References\n\n" + "\n".join(references))

    return "\n\n".join(parts).strip() + "\n"


def render_index_page(pages: list[PageDraft]) -> str:
    parts = ["# Workspace Wiki Index"]
    if not pages:
        parts.append("No ready sources have been compiled yet.")
        return "\n\n".join(parts) + "\n"

    page_lines = []
    coverage_lines = []
    backlink_lines = []
    for page in pages:
        page_lines.append(f"- [[{page.title}]] (`{page.slug}`) — {len(page.citations)} citations")
        coverage_lines.append(
            f"- {page.title}: {len(page.source_ids)} source, {len(page.citations)} citations"
        )
        if page.backlinks:
            backlink_lines.append(f"- [[{page.title}]] ← " + ", ".join(page.backlinks))

    parts.append("## Pages\n\n" + "\n".join(page_lines))
    parts.append("## Source coverage\n\n" + "\n".join(coverage_lines))
    if backlink_lines:
        parts.append("## Backlinks\n\n" + "\n".join(backlink_lines))
    return "\n\n".join(parts) + "\n"


async def _load_sources(
    user: User,
    source_ids: list[uuid.UUID] | None,
    db: AsyncSession,
    require_all: bool = True,
) -> list[Source]:
    content_size_statement = (
        select(func.coalesce(func.sum(func.length(SourceChunk.content)), 0))
        .join(Source, SourceChunk.source_id == Source.id)
        .where(Source.user_id == user.id, Source.status == SourceStatus.READY)
    )
    if source_ids is not None:
        content_size_statement = content_size_statement.where(Source.id.in_(source_ids))
    if await db.scalar(content_size_statement) > MAX_WIKI_CONTENT_CHARS:
        raise WikiBaseError(
            413,
            "wiki_too_large",
            "Wiki compilation input exceeds 5,000,000 characters",
        )
    statement = (
        select(Source)
        .where(
            Source.user_id == user.id,
            Source.status == SourceStatus.READY,
            Source.chunks.any(),
        )
        .options(selectinload(Source.chunks))
        .order_by(Source.title.asc(), Source.id.asc())
        .limit(MAX_WIKI_PAGES + 1)
    )
    if source_ids is not None:
        statement = statement.where(Source.id.in_(source_ids))

    result = await db.execute(statement)
    sources = list(result.scalars().unique().all())
    if len(sources) > MAX_WIKI_PAGES:
        raise WikiBaseError(413, "wiki_too_large", "Wiki compilation is limited to 100 sources")

    if require_all and source_ids is not None and len(sources) != len(set(source_ids)):
        raise NotFoundError("One or more ready sources were not found")

    return sources


async def _load_existing_compiled_source_ids(user: User, db: AsyncSession) -> list[uuid.UUID]:
    result = await db.execute(
        select(WikiPage.source_ids).where(
            WikiPage.user_id == user.id,
            WikiPage.page_type == "source",
            WikiPage.is_current.is_(True),
        )
    )
    source_ids: list[uuid.UUID] = []
    seen: set[uuid.UUID] = set()
    for row in result:
        for source_id in row.source_ids:
            if source_id not in seen:
                seen.add(source_id)
                source_ids.append(source_id)
    return source_ids


async def _lock_user_wiki(user: User, db: AsyncSession) -> None:
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"wiki:{user.id}"},
    )


async def _store_revision(
    page: WikiPage, user: User, change_summary: str, db: AsyncSession
) -> None:
    revision_number = (
        await db.scalar(
            select(func.max(WikiRevision.revision_number)).where(WikiRevision.page_id == page.id)
        )
        or 0
    ) + 1
    db.add(
        WikiRevision(
            user_id=user.id,
            page_id=page.id,
            revision_number=revision_number,
            title=page.title,
            markdown=page.markdown,
            source_ids=list(page.source_ids),
            citation_count=page.citation_count,
            change_summary=change_summary,
        )
    )


async def compile_workspace_wiki(
    user: User,
    db: AsyncSession,
    source_ids: list[uuid.UUID] | None = None,
) -> list[WikiPage]:
    await _lock_user_wiki(user, db)

    if source_ids is None:
        sources = await _load_sources(user, None, db)
    else:
        await _load_sources(user, source_ids, db, require_all=True)
        existing_source_ids = await _load_existing_compiled_source_ids(user, db)
        compile_source_ids = list(dict.fromkeys([*existing_source_ids, *source_ids]))
        sources = await _load_sources(user, compile_source_ids, db, require_all=False)

    used_slugs = {"index"}
    drafts = [
        build_source_page_draft(source, _unique_slug(source.title, used_slugs))
        for source in sources
    ]
    backlink_map = build_backlink_map(drafts)
    pages_by_slug = {page.slug: page for page in drafts}
    for page in drafts:
        page.backlinks = backlink_map[page.slug]

    existing = list(
        (
            await db.execute(
                select(WikiPage)
                .where(WikiPage.user_id == user.id)
                .options(selectinload(WikiPage.citations))
            )
        )
        .scalars()
        .unique()
    )
    source_pages = {
        page.source_ids[0]: page
        for page in existing
        if page.page_type == "source" and len(page.source_ids) == 1
    }
    index_page = next((page for page in existing if page.page_type == "index"), None)
    for page in existing:
        page.slug = f"__compiling-{page.id}"
    await db.flush()

    stored_pages: list[WikiPage] = []
    active_page_ids: set[uuid.UUID] = set()
    for draft in drafts:
        page = source_pages.get(draft.source_ids[0])
        markdown = render_page_markdown(draft, pages_by_slug)
        created = page is None
        if page is None:
            page = WikiPage(
                user_id=user.id,
                slug=draft.slug,
                title=draft.title,
                page_type="source",
                markdown=markdown,
                summary=draft.summary,
                source_ids=draft.source_ids,
                citation_count=0,
                backlinks=[],
                citations=[],
            )
            db.add(page)
            await db.flush()
        changed = created or any(
            (
                page.title != draft.title,
                page.markdown != markdown,
                page.source_ids != draft.source_ids,
                page.backlinks != draft.backlinks,
            )
        )
        page.slug = draft.slug
        page.is_current = True
        page.title = draft.title
        page.markdown = markdown
        page.summary = draft.summary
        page.source_ids = draft.source_ids
        page.citation_count = len(draft.citations)
        page.backlinks = draft.backlinks
        page.citations.clear()
        for citation in draft.citations:
            page.citations.append(
                WikiCitation(
                    source_id=citation.source_id,
                    source_chunk_id=citation.source_chunk_id,
                    citation_key=citation.citation_key,
                    citation_ref=citation.citation_ref,
                    source_title=citation.source_title,
                    location_label=citation.location_label,
                    chunk_index=citation.chunk_index,
                    snippet=citation.snippet,
                )
            )
        if changed:
            await _store_revision(
                page, user, "Initial compilation" if created else "Source content changed", db
            )
        active_page_ids.add(page.id)
        stored_pages.append(page)

    index_markdown = render_index_page(drafts)
    index_created = index_page is None
    if index_page is None:
        index_page = WikiPage(
            user_id=user.id,
            slug="index",
            title="Workspace Wiki Index",
            page_type="index",
            markdown=index_markdown,
            summary="",
            source_ids=[],
            citation_count=0,
            backlinks=[],
            citations=[],
        )
        db.add(index_page)
        await db.flush()
    index_changed = index_created or index_page.markdown != index_markdown
    index_page.slug = "index"
    index_page.is_current = True
    index_page.title = "Workspace Wiki Index"
    index_page.markdown = index_markdown
    index_page.summary = f"{len(drafts)} compiled pages"
    index_page.source_ids = [source.id for source in sources]
    index_page.citation_count = sum(len(draft.citations) for draft in drafts)
    index_page.backlinks = []
    index_page.citations.clear()
    if index_changed:
        await _store_revision(
            index_page,
            user,
            "Initial compilation" if index_created else "Workspace index changed",
            db,
        )
    active_page_ids.add(index_page.id)
    stored_pages.insert(0, index_page)

    for page in existing:
        if page.id not in active_page_ids:
            page.is_current = False
            page.slug = f"__retired-{page.id}"

    await db.commit()
    for page in stored_pages:
        await db.refresh(page, attribute_names=["citations", "updated_at"])
    return stored_pages


async def list_wiki_pages(user: User, db: AsyncSession) -> list[WikiPage]:
    result = await db.execute(
        select(WikiPage)
        .where(WikiPage.user_id == user.id, WikiPage.is_current.is_(True))
        .options(selectinload(WikiPage.citations))
        .order_by(WikiPage.page_type.asc(), WikiPage.title.asc())
        .limit(MAX_WIKI_PAGES + 1)
    )
    return list(result.scalars().unique().all())


async def get_wiki_page(user: User, slug: str, db: AsyncSession) -> WikiPage:
    result = await db.execute(
        select(WikiPage)
        .where(
            WikiPage.user_id == user.id,
            WikiPage.slug == slug,
            WikiPage.is_current.is_(True),
        )
        .options(selectinload(WikiPage.citations))
    )
    page = result.scalar_one_or_none()
    if page is None:
        raise NotFoundError("Wiki page not found")
    return page
