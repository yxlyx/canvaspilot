import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError
from app.models.curriculum import ModuleEnrollment
from app.models.source_chunk import active_source_chunk_sql
from app.services.curriculum_coverage import current_confirmed_source_ids
from app.services.embedding import embed_query

TOP_K = 5
SCORE_THRESHOLD = 0.7


@dataclass
class RetrievedChunk:
    content: str
    score: float
    source_title: str
    source_url: str
    source_type: str
    source_id: str | None = None
    citation_ref: str | None = None


_LEXICAL_STOP_WORDS = {
    "a",
    "about",
    "an",
    "and",
    "are",
    "does",
    "explain",
    "for",
    "from",
    "how",
    "in",
    "is",
    "my",
    "of",
    "on",
    "or",
    "summarise",
    "summary",
    "that",
    "the",
    "this",
    "to",
    "what",
    "when",
    "where",
    "which",
    "who",
    "why",
    "your",
}


def _lexical_query(query: str) -> str:
    terms: list[str] = []
    for term in re.findall(r"[a-z0-9]{2,}", query.casefold()):
        if term in _LEXICAL_STOP_WORDS or term in terms:
            continue
        terms.append(term)
        if len(terms) == 12:
            break
    return " OR ".join(terms)


def _lexical_score(rank: float) -> float:
    return min(0.9, 0.6 + max(0.0, rank))


async def _retrieve_lexically(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
    module_id: uuid.UUID | None,
    enrollment_id: uuid.UUID | None,
    confirmed_source_ids: set[uuid.UUID],
    top_k: int,
) -> list[RetrievedChunk]:
    lexical_query = _lexical_query(query)
    if not lexical_query:
        return []
    params: dict = {
        "user_id": str(user_id),
        "lexical_query": lexical_query,
        "top_k": top_k,
    }
    chunks: list[RetrievedChunk] = []

    if enrollment_id is None:
        module_sql = """
            SELECT cc.content, cc.source_title, cc.source_url, cc.source_type,
                   ts_rank_cd(
                       to_tsvector('english', coalesce(cc.content, '')),
                       websearch_to_tsquery('english', :lexical_query)
                   ) AS rank
            FROM content_chunks cc
            JOIN modules m ON cc.module_id = m.id
            WHERE m.user_id = :user_id
              AND to_tsvector('english', coalesce(cc.content, ''))
                  @@ websearch_to_tsquery('english', :lexical_query)
        """
        if module_id is not None:
            module_sql += " AND cc.module_id = :module_id"
            params["module_id"] = str(module_id)
        module_sql += " ORDER BY rank DESC, cc.created_at DESC LIMIT :top_k"
        rows = (await db.execute(text(module_sql), params)).fetchall()
        chunks.extend(
            RetrievedChunk(
                content=row.content,
                score=_lexical_score(float(row.rank)),
                source_title=row.source_title,
                source_url=row.source_url,
                source_type=row.source_type,
            )
            for row in rows
        )

    if module_id is None:
        source_sql = f"""
            SELECT sc.content, sc.citation_ref,
                   ts_rank_cd(
                       to_tsvector('english', coalesce(sc.content, '')),
                       websearch_to_tsquery('english', :lexical_query)
                   ) AS rank,
                   s.id AS source_id, s.title AS source_title, s.source_url, s.source_type
            FROM source_chunks sc
            JOIN sources s ON sc.source_id = s.id
            WHERE s.user_id = :user_id AND s.status = 'ready'
              AND {active_source_chunk_sql("sc", "s")}
              AND to_tsvector('english', coalesce(sc.content, ''))
                  @@ websearch_to_tsquery('english', :lexical_query)
        """
        if enrollment_id is not None:
            source_sql += """
              AND (
                s.enrollment_id = :enrollment_id
                OR (
                  s.enrollment_id IS NULL
                  AND s.id::text = ANY(CAST(:confirmed_source_ids AS text[]))
                )
              )
            """
            params["enrollment_id"] = str(enrollment_id)
            params["confirmed_source_ids"] = sorted(str(item) for item in confirmed_source_ids)
        source_sql += " ORDER BY rank DESC, sc.created_at DESC LIMIT :top_k"
        rows = (await db.execute(text(source_sql), params)).fetchall()
        chunks.extend(
            RetrievedChunk(
                content=row.content,
                score=_lexical_score(float(row.rank)),
                source_title=row.source_title,
                source_url=row.source_url,
                source_type=row.source_type,
                source_id=str(row.source_id),
                citation_ref=row.citation_ref,
            )
            for row in rows
        )

    chunks.sort(key=lambda chunk: chunk.score, reverse=True)
    return chunks[:top_k]


async def retrieve(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
    module_id: uuid.UUID | None = None,
    enrollment_id: uuid.UUID | None = None,
    top_k: int = TOP_K,
) -> list[RetrievedChunk]:
    confirmed_source_ids: set[uuid.UUID] = set()
    if enrollment_id is not None:
        enrollment = await db.scalar(
            select(ModuleEnrollment).where(
                ModuleEnrollment.id == enrollment_id,
                ModuleEnrollment.user_id == user_id,
                ModuleEnrollment.archived.is_(False),
            )
        )
        if enrollment is None:
            raise NotFoundError("Active module enrollment not found")
        confirmed_source_ids = await current_confirmed_source_ids(enrollment, db)
    try:
        query_embedding = await embed_query(query)
    except Exception:
        return await _retrieve_lexically(
            query,
            user_id,
            db,
            module_id,
            enrollment_id,
            confirmed_source_ids,
            top_k,
        )

    embedding_literal = "[" + ",".join(str(v) for v in query_embedding) + "]"
    now = datetime.now(UTC)
    chunks: list[RetrievedChunk] = []

    params: dict = {"user_id": str(user_id), "query_vec": embedding_literal, "top_k": top_k}

    if enrollment_id is None:
        module_sql = """
            SELECT cc.content, cc.source_title, cc.source_url, cc.source_type, cc.created_at,
                   cc.embedding <=> :query_vec AS distance
            FROM content_chunks cc
            JOIN modules m ON cc.module_id = m.id
            WHERE m.user_id = :user_id
        """
        if module_id:
            module_sql += " AND cc.module_id = :module_id"
            params["module_id"] = str(module_id)
        module_sql += " ORDER BY distance LIMIT :top_k"
        rows = (await db.execute(text(module_sql), params)).fetchall()
        for row in rows:
            distance = float(row.distance)
            similarity = 1.0 - distance
            if similarity < SCORE_THRESHOLD:
                continue
            days_old = (now - row.created_at.replace(tzinfo=UTC)).days
            recency_boost = min(1.1, 1.0 + 0.1 * (1.0 - days_old / 90.0))
            chunks.append(
                RetrievedChunk(
                    content=row.content,
                    score=similarity * recency_boost,
                    source_title=row.source_title,
                    source_url=row.source_url,
                    source_type=row.source_type,
                )
            )

    if module_id is None:
        source_sql = f"""
            SELECT sc.content, sc.citation_ref, sc.created_at,
                   sc.embedding <=> :query_vec AS distance,
                   s.id AS source_id, s.title AS source_title, s.source_url, s.source_type
            FROM source_chunks sc
            JOIN sources s ON sc.source_id = s.id
            WHERE s.user_id = :user_id AND s.status = 'ready'
              AND sc.embedding IS NOT NULL
              AND {active_source_chunk_sql("sc", "s")}
        """
        if enrollment_id is not None:
            source_sql += """
              AND (
                s.enrollment_id = :enrollment_id
                OR (
                  s.enrollment_id IS NULL
                  AND s.id::text = ANY(CAST(:confirmed_source_ids AS text[]))
                )
              )
            """
            params["enrollment_id"] = str(enrollment_id)
            params["confirmed_source_ids"] = sorted(str(item) for item in confirmed_source_ids)
        source_sql += " ORDER BY distance LIMIT :top_k"
        result = await db.execute(text(source_sql), params)
        for row in result.fetchall():
            distance = float(row.distance)
            similarity = 1.0 - distance

            if similarity < SCORE_THRESHOLD:
                continue

            days_old = (now - row.created_at.replace(tzinfo=UTC)).days
            recency_boost = min(1.1, 1.0 + 0.1 * (1.0 - days_old / 90.0))
            boosted_score = similarity * recency_boost

            chunks.append(
                RetrievedChunk(
                    content=row.content,
                    score=boosted_score,
                    source_title=row.source_title,
                    source_url=row.source_url,
                    source_type=row.source_type,
                    source_id=str(row.source_id),
                    citation_ref=row.citation_ref,
                )
            )

    chunks.sort(key=lambda c: c.score, reverse=True)
    return chunks[:top_k]


def build_context(chunks: list[RetrievedChunk]) -> str:
    parts = []
    for i, chunk in enumerate(chunks, 1):
        parts.append(f"[{i}] (Source: {chunk.source_title}) {chunk.content}")
    return "\n\n".join(parts)
