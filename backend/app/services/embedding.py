import asyncio
from typing import Any

from openai import AsyncOpenAI
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings

BATCH_SIZE = 100
MODEL = "text-embedding-3-small"


async def embed_chunks(chunks: list[Any], db: AsyncSession) -> None:
    settings = get_settings()
    client = AsyncOpenAI(api_key=settings.openai_api_key)

    for i in range(0, len(chunks), BATCH_SIZE):
        batch = chunks[i : i + BATCH_SIZE]
        texts = [c.content for c in batch]

        for attempt in range(3):
            try:
                response = await client.embeddings.create(model=MODEL, input=texts)
                break
            except Exception:
                if attempt == 2:
                    raise
                await asyncio.sleep(2**attempt)

        for chunk, embedding_data in zip(batch, response.data):
            chunk.embedding = embedding_data.embedding

    await db.flush()


async def embed_query(query: str) -> list[float]:
    settings = get_settings()
    client = AsyncOpenAI(api_key=settings.openai_api_key)
    response = await client.embeddings.create(model=MODEL, input=[query])
    return response.data[0].embedding
