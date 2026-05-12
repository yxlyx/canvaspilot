import json
import re
from collections.abc import AsyncGenerator

from openai import AsyncOpenAI

from app.config import get_settings
from app.schemas.chat import ChatMessage
from app.services.retrieval import RetrievedChunk

SYSTEM_PROMPT = (
    "You are CanvasPilot, an academic assistant for NUS students. "
    "Answer questions using ONLY the provided context from Canvas "
    "module content.\n\n"
    "Rules:\n"
    "- Cite sources using [1], [2] etc. matching the context numbers\n"
    "- If the context doesn't contain enough information, say "
    "\"I don't have enough information from your Canvas modules "
    'to answer this"\n'
    "- Be concise and accurate\n"
    "- Never fabricate information not in the context\n\n"
    "Context:\n{context}"
)


async def stream_rag_response(
    query: str,
    context: str,
    chunks: list[RetrievedChunk],
    history: list[ChatMessage],
) -> AsyncGenerator[str, None]:
    settings = get_settings()
    client = AsyncOpenAI(api_key=settings.openai_api_key)

    messages = [{"role": "system", "content": SYSTEM_PROMPT.format(context=context)}]
    for msg in history[-10:]:
        messages.append({"role": msg.role, "content": msg.content})
    messages.append({"role": "user", "content": query})

    full_response = ""

    stream = await client.chat.completions.create(
        model="gpt-4o",
        messages=messages,
        stream=True,
        temperature=0.3,
        max_tokens=1024,
    )

    async for chunk in stream:
        delta = chunk.choices[0].delta
        if delta.content:
            full_response += delta.content
            token_data = json.dumps({"text": delta.content})
            yield f"event: token\ndata: {token_data}\n\n"

    citation_refs = set(int(m) for m in re.findall(r"\[(\d+)\]", full_response))
    citations = []
    for ref in sorted(citation_refs):
        idx = ref - 1
        if 0 <= idx < len(chunks):
            c = chunks[idx]
            citations.append(
                {
                    "title": c.source_title,
                    "url": c.source_url,
                    "snippet": c.content[:200],
                }
            )

    if citations:
        cite_data = json.dumps({"citations": citations})
        yield f"event: citations\ndata: {cite_data}\n\n"

    avg_score = sum(c.score for c in chunks) / len(chunks) if chunks else 0
    done_data = json.dumps(
        {
            "grounded": bool(citations),
            "confidence": round(avg_score, 2),
        }
    )
    yield f"event: done\ndata: {done_data}\n\n"
