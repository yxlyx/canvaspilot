import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.source_chunk import active_source_chunk_sql
from app.schemas.search import WorkspaceSearchResult
from app.services.embedding import embed_query

SEARCH_LIMIT = 10
MIN_SEARCH_SCORE = 0.55
VECTOR_SCORE_THRESHOLD = 0.7
_SNIPPET_RE = re.compile(r"\s+")


@dataclass
class SearchCandidate:
    result_type: str
    title: str
    source_type: str
    snippet: str
    score: float
    updated_at: datetime
    citation_ref: str | None = None
    source_id: uuid.UUID | None = None
    source_chunk_id: uuid.UUID | None = None
    content_chunk_id: uuid.UUID | None = None
    wiki_page_id: uuid.UUID | None = None
    wiki_slug: str | None = None
    url: str = ""


def _clean_query(query: str) -> str:
    return " ".join(query.strip().split())


def _snippet(value: str, query: str, limit: int = 220) -> str:
    compact = _SNIPPET_RE.sub(" ", value).strip()
    if len(compact) <= limit:
        return compact

    query_index = compact.lower().find(query.lower()) if query else -1
    if query_index < 0:
        return compact[: limit - 1].rstrip() + "…"

    start = max(0, query_index - limit // 3)
    end = min(len(compact), start + limit)
    snippet = compact[start:end].strip()
    if start > 0:
        snippet = "…" + snippet
    if end < len(compact):
        snippet += "…"
    return snippet


def _source_record_score(row: Any, query: str) -> float:
    lowered_query = query.lower()
    title = row.title.lower()
    citation = row.citation_label.lower()
    source_url = (row.source_url or "").lower()
    tags = [tag.lower() for tag in (row.topic_tags or [])]

    if lowered_query == title:
        return 0.93
    if lowered_query in title:
        return 0.88
    if lowered_query in tags:
        return 0.82
    if any(lowered_query in tag for tag in tags):
        return 0.76
    if lowered_query in citation:
        return 0.72
    if source_url and lowered_query in source_url:
        return 0.66
    return 0.0


def _wiki_score(row: Any, query: str) -> float:
    lowered_query = query.lower()
    title = row.title.lower()
    summary = (row.summary or "").lower()
    markdown = row.markdown.lower()

    if lowered_query == title:
        return 0.91
    if lowered_query in title:
        return 0.86
    if lowered_query in summary:
        return 0.76
    if lowered_query in markdown:
        return 0.68
    return 0.0


def _boosted_vector_score(row: Any, similarity: float) -> float:
    now = datetime.now(UTC)
    days_old = (now - row.created_at.replace(tzinfo=UTC)).days
    recency_boost = max(0.85, min(1.1, 1.0 + 0.1 * (1.0 - days_old / 90.0)))
    return max(0.0, min(1.0, similarity * recency_boost))


def _embedding_literal(query_embedding: list[float]) -> str:
    return "[" + ",".join(str(v) for v in query_embedding) + "]"


def _add_candidate(
    candidates: dict[tuple[str, str], SearchCandidate], candidate: SearchCandidate
) -> None:
    key = (
        candidate.result_type,
        str(
            candidate.source_chunk_id
            or candidate.content_chunk_id
            or candidate.wiki_page_id
            or candidate.source_id
            or candidate.title
        ),
    )
    existing = candidates.get(key)
    if existing is None or candidate.score > existing.score:
        candidates[key] = candidate


async def _source_chunk_candidates(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
    limit: int,
    query_embedding: list[float] | None,
) -> list[SearchCandidate]:
    if query_embedding is None:
        return []

    result = await db.execute(
        text(
            f"""
            SELECT *
            FROM (
                SELECT sc.id AS source_chunk_id, sc.content, sc.citation_ref,
                       sc.location_label, sc.created_at,
                       sc.embedding <=> :query_vec AS distance,
                       LEAST(
                           1.0,
                           GREATEST(
                               0.0,
                               (1.0 - (sc.embedding <=> :query_vec))
                               * GREATEST(
                                   0.85,
                                   LEAST(
                                       1.1,
                                       1.0 + 0.1 * (
                                           1.0 - (
                                               EXTRACT(EPOCH FROM (NOW() - sc.created_at))
                                               / 86400.0 / 90.0
                                           )
                                       )
                                   )
                               )
                           )
                       ) AS boosted_score,
                       s.id AS source_id, s.title, s.source_type, s.source_url, s.updated_at
                FROM source_chunks sc
                JOIN sources s ON sc.source_id = s.id
                WHERE s.user_id = :user_id AND s.status = 'ready' AND sc.embedding IS NOT NULL
                  AND {active_source_chunk_sql("sc", "s")}
            ) ranked
            WHERE (1.0 - distance) >= :score_threshold
            ORDER BY boosted_score DESC, updated_at DESC, title ASC
            LIMIT :limit
            """
        ),
        {
            "user_id": str(user_id),
            "query_vec": _embedding_literal(query_embedding),
            "score_threshold": VECTOR_SCORE_THRESHOLD,
            "limit": limit,
        },
    )

    candidates: list[SearchCandidate] = []
    for row in result.fetchall():
        similarity = 1.0 - float(row.distance)
        if similarity < VECTOR_SCORE_THRESHOLD:
            continue
        candidates.append(
            SearchCandidate(
                result_type="source_chunk",
                title=row.title,
                source_type=str(row.source_type),
                snippet=_snippet(row.content, query),
                score=float(row.boosted_score),
                citation_ref=row.citation_ref,
                source_id=row.source_id,
                source_chunk_id=row.source_chunk_id,
                url=row.source_url,
                updated_at=row.updated_at,
            )
        )
    return candidates


async def _content_chunk_candidates(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
    limit: int,
    query_embedding: list[float] | None,
) -> list[SearchCandidate]:
    if query_embedding is None:
        return []

    result = await db.execute(
        text(
            """
            SELECT *
            FROM (
                SELECT cc.id AS content_chunk_id, cc.content, cc.source_title, cc.source_url,
                       cc.source_type, cc.created_at, m.updated_at,
                       cc.embedding <=> :query_vec AS distance,
                       LEAST(
                           1.0,
                           GREATEST(
                               0.0,
                               (1.0 - (cc.embedding <=> :query_vec))
                               * GREATEST(
                                   0.85,
                                   LEAST(
                                       1.1,
                                       1.0 + 0.1 * (
                                           1.0 - (
                                               EXTRACT(EPOCH FROM (NOW() - cc.created_at))
                                               / 86400.0 / 90.0
                                           )
                                       )
                                   )
                               )
                           )
                       ) AS boosted_score
                FROM content_chunks cc
                JOIN modules m ON cc.module_id = m.id
                WHERE m.user_id = :user_id AND cc.embedding IS NOT NULL
            ) ranked
            WHERE (1.0 - distance) >= :score_threshold
            ORDER BY boosted_score DESC, updated_at DESC, source_title ASC
            LIMIT :limit
            """
        ),
        {
            "user_id": str(user_id),
            "query_vec": _embedding_literal(query_embedding),
            "score_threshold": VECTOR_SCORE_THRESHOLD,
            "limit": limit,
        },
    )

    candidates: list[SearchCandidate] = []
    for row in result.fetchall():
        similarity = 1.0 - float(row.distance)
        if similarity < VECTOR_SCORE_THRESHOLD:
            continue
        candidates.append(
            SearchCandidate(
                result_type="content_chunk",
                title=row.source_title,
                source_type=str(row.source_type),
                snippet=_snippet(row.content, query),
                score=float(row.boosted_score),
                citation_ref=row.source_title,
                content_chunk_id=row.content_chunk_id,
                url=row.source_url,
                updated_at=row.updated_at,
            )
        )
    return candidates


async def _source_record_candidates(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
) -> list[SearchCandidate]:
    result = await db.execute(
        text(
            """
            SELECT id, title, source_type, source_url, citation_label, topic_tags, updated_at
            FROM sources
            WHERE user_id = :user_id
              AND status != 'archived'
              AND (
                  title ILIKE :pattern
                  OR citation_label ILIKE :pattern
                  OR source_url ILIKE :pattern
                  OR EXISTS (
                      SELECT 1 FROM unnest(topic_tags) AS tag WHERE tag ILIKE :pattern
                  )
              )
            ORDER BY updated_at DESC, title ASC
            LIMIT 50
            """
        ),
        {"user_id": str(user_id), "pattern": f"%{query}%"},
    )

    candidates: list[SearchCandidate] = []
    for row in result.fetchall():
        score = _source_record_score(row, query)
        if score < MIN_SEARCH_SCORE:
            continue
        tags = ", ".join(row.topic_tags or [])
        base_snippet = tags or row.citation_label or row.source_url or row.title
        candidates.append(
            SearchCandidate(
                result_type="source",
                title=row.title,
                source_type=str(row.source_type),
                snippet=_snippet(base_snippet, query),
                score=score,
                citation_ref=row.citation_label,
                source_id=row.id,
                url=row.source_url,
                updated_at=row.updated_at,
            )
        )
    return candidates


async def _wiki_candidates(
    query: str, user_id: uuid.UUID, db: AsyncSession
) -> list[SearchCandidate]:
    result = await db.execute(
        text(
            """
            SELECT id, slug, title, page_type, summary, markdown, citation_count, updated_at
            FROM wiki_pages
            WHERE user_id = :user_id
              AND (
                  title ILIKE :pattern
                  OR summary ILIKE :pattern
                  OR markdown ILIKE :pattern
              )
            ORDER BY updated_at DESC, title ASC
            LIMIT 50
            """
        ),
        {"user_id": str(user_id), "pattern": f"%{query}%"},
    )

    candidates: list[SearchCandidate] = []
    for row in result.fetchall():
        score = _wiki_score(row, query)
        if score < MIN_SEARCH_SCORE:
            continue
        snippet_source = (
            row.summary if query.lower() in (row.summary or "").lower() else row.markdown
        )
        candidates.append(
            SearchCandidate(
                result_type="wiki_page",
                title=row.title,
                source_type=f"wiki:{row.page_type}",
                snippet=_snippet(snippet_source, query),
                score=score,
                citation_ref=f"{row.citation_count} citations",
                wiki_page_id=row.id,
                wiki_slug=row.slug,
                url=f"/wiki/{row.slug}",
                updated_at=row.updated_at,
            )
        )
    return candidates


async def _query_embedding(query: str) -> list[float] | None:
    try:
        return await embed_query(query)
    except Exception:
        return None


async def search_workspace(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
    limit: int = SEARCH_LIMIT,
) -> list[WorkspaceSearchResult]:
    cleaned_query = _clean_query(query)
    if not cleaned_query:
        return []

    bounded_limit = max(1, min(limit, 50))
    candidates: dict[tuple[str, str], SearchCandidate] = {}
    query_embedding = await _query_embedding(cleaned_query)

    for candidate in await _source_chunk_candidates(
        cleaned_query, user_id, db, bounded_limit, query_embedding
    ):
        _add_candidate(candidates, candidate)
    for candidate in await _content_chunk_candidates(
        cleaned_query, user_id, db, bounded_limit, query_embedding
    ):
        _add_candidate(candidates, candidate)
    for candidate in await _source_record_candidates(cleaned_query, user_id, db):
        _add_candidate(candidates, candidate)
    for candidate in await _wiki_candidates(cleaned_query, user_id, db):
        _add_candidate(candidates, candidate)

    ranked = sorted(candidates.values(), key=lambda item: (-item.score, item.title.lower()))
    return [
        WorkspaceSearchResult(
            result_type=item.result_type,
            title=item.title,
            source_type=item.source_type,
            snippet=item.snippet,
            score=round(item.score, 3),
            citation_ref=item.citation_ref,
            source_id=item.source_id,
            source_chunk_id=item.source_chunk_id,
            content_chunk_id=item.content_chunk_id,
            wiki_page_id=item.wiki_page_id,
            wiki_slug=item.wiki_slug,
            url=item.url,
            updated_at=item.updated_at,
        )
        for item in ranked[:bounded_limit]
    ]
