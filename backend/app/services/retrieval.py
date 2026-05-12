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


async def retrieve(
    query: str,
    user_id: uuid.UUID,
    db: AsyncSession,
    module_id: uuid.UUID | None = None,
    top_k: int = TOP_K,
) -> list[RetrievedChunk]:
    query_embedding = await embed_query(query)

    embedding_literal = "[" + ",".join(str(v) for v in query_embedding) + "]"

    sql = """
        SELECT cc.content, cc.source_title, cc.source_url, cc.source_type, cc.created_at,
               cc.embedding <=> :query_vec AS distance
        FROM content_chunks cc
        JOIN modules m ON cc.module_id = m.id
        WHERE m.user_id = :user_id
    """
    params: dict = {"user_id": str(user_id), "query_vec": embedding_literal}

    if module_id:
        sql += " AND cc.module_id = :module_id"
        params["module_id"] = str(module_id)

    sql += " ORDER BY distance LIMIT :top_k"
    params["top_k"] = top_k

    result = await db.execute(text(sql), params)
    rows = result.fetchall()

    now = datetime.now(UTC)
    chunks: list[RetrievedChunk] = []

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

    chunks.sort(key=lambda c: c.score, reverse=True)
    return chunks


def build_context(chunks: list[RetrievedChunk]) -> str:
    parts = []
    for i, chunk in enumerate(chunks, 1):
        parts.append(f"[{i}] (Source: {chunk.source_title}) {chunk.content}")
    return "\n\n".join(parts)
