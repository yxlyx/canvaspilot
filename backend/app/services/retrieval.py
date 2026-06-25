import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

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


async def retrieve(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
    module_id: uuid.UUID | None = None,
    top_k: int = TOP_K,
) -> list[RetrievedChunk]:
    query_embedding = await embed_query(query)

    embedding_literal = "[" + ",".join(str(v) for v in query_embedding) + "]"
    now = datetime.now(UTC)
    chunks: list[RetrievedChunk] = []

    module_sql = """
        SELECT cc.content, cc.source_title, cc.source_url, cc.source_type, cc.created_at,
               cc.embedding <=> :query_vec AS distance
        FROM content_chunks cc
        JOIN modules m ON cc.module_id = m.id
        WHERE m.user_id = :user_id
    """
    params: dict = {"user_id": str(user_id), "query_vec": embedding_literal}

    if module_id:
        module_sql += " AND cc.module_id = :module_id"
        params["module_id"] = str(module_id)

    module_sql += " ORDER BY distance LIMIT :top_k"
    params["top_k"] = top_k

    result = await db.execute(text(module_sql), params)
    rows = result.fetchall()

    for row in rows:
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
            )
        )

    if module_id is None:
        source_sql = """
            SELECT sc.content, sc.citation_ref, sc.created_at,
                   sc.embedding <=> :query_vec AS distance,
                   s.id AS source_id, s.title AS source_title, s.source_url, s.source_type
            FROM source_chunks sc
            JOIN sources s ON sc.source_id = s.id
            WHERE s.user_id = :user_id AND s.status = 'ready'
            ORDER BY distance
            LIMIT :top_k
        """
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
