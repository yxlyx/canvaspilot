import json
import re
from collections.abc import AsyncGenerator
from dataclasses import dataclass
from typing import Any

from openai import AsyncAzureOpenAI, AsyncOpenAI, AuthenticationError
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import WikiBaseError
from app.models.user import User
from app.schemas.chat import ChatMessage
from app.services.providers import (
    GenerationProvider,
    force_refresh_generation_provider,
    mark_local_codex_unavailable,
    resolve_generation_provider,
)
from app.services.retrieval import RetrievedChunk

SYSTEM_PROMPT = (
    "You are WikiBase, an academic study helper for NUS students. "
    "Answer questions using ONLY the provided workspace source context.\n\n"
    "Rules:\n"
    "- Cite sources using [1], [2] etc. matching the context numbers\n"
    "- If the context doesn't contain enough information, say "
    "\"I don't have enough information from your workspace sources "
    'to answer this"\n'
    "- Be concise and accurate\n"
    "- Never fabricate information not in the context\n\n"
    "Context:\n{context}"
)


@dataclass(frozen=True)
class PreparedRagStream:
    provider: GenerationProvider
    stream: Any


def _provider_client(provider):
    if provider.provider == "azure_openai":
        return AsyncAzureOpenAI(
            api_key=provider.api_key,
            azure_endpoint=provider.endpoint,
            api_version="2024-10-21",
        )
    return AsyncOpenAI(api_key=provider.api_key, base_url=provider.endpoint)


async def prepare_rag_stream(
    query: str,
    context: str,
    history: list[ChatMessage],
    user: User | None,
    db: AsyncSession | None,
    provider: GenerationProvider,
) -> PreparedRagStream:
    messages = [{"role": "system", "content": SYSTEM_PROMPT.format(context=context)}]
    for msg in history[-10:]:
        messages.append({"role": msg.role, "content": msg.content})
    messages.append({"role": "user", "content": query})
    if provider.transport == "codex_cli":
        from app.services.local_codex import generate_with_local_codex

        transcript = "\n\n".join(
            f"{message['role'].upper()}:\n{message['content']}" for message in messages
        )
        prompt = (
            "Answer the academic question below. Return only the final answer text. "
            "Do not inspect local files, run commands, or use tools.\n\n"
            f"{transcript}"
        )
        try:
            answer = await generate_with_local_codex(prompt, provider.model)
        except WikiBaseError as exc:
            await mark_local_codex_unavailable(user, db, exc.error, exc.detail)
            raise
        return PreparedRagStream(provider=provider, stream=answer)
    client = _provider_client(provider)
    if provider.transport == "responses":
        headers = {"originator": "canvaspilot"}
        if provider.account_id:
            headers["chatgpt-account-id"] = provider.account_id
        try:
            stream = await client.responses.create(
                model=provider.model,
                input=messages,
                stream=True,
                max_output_tokens=1024,
                extra_headers=headers,
            )
        except AuthenticationError:
            provider = await force_refresh_generation_provider(user, db)
            client = _provider_client(provider)
            headers = {"originator": "canvaspilot"}
            if provider.account_id:
                headers["chatgpt-account-id"] = provider.account_id
            stream = await client.responses.create(
                model=provider.model,
                input=messages,
                stream=True,
                max_output_tokens=1024,
                extra_headers=headers,
            )
    else:
        stream = await client.chat.completions.create(
            model=provider.model,
            messages=messages,
            stream=True,
            temperature=0.3,
            max_tokens=1024,
        )
    return PreparedRagStream(provider=provider, stream=stream)


async def stream_rag_response(
    query: str,
    context: str,
    chunks: list[RetrievedChunk],
    history: list[ChatMessage],
    user: User | None = None,
    db: AsyncSession | None = None,
    provider: GenerationProvider | None = None,
    prepared: PreparedRagStream | None = None,
) -> AsyncGenerator[dict[str, str], None]:
    if prepared is None:
        if provider is None:
            provider = await resolve_generation_provider(user, db)
        prepared = await prepare_rag_stream(query, context, history, user, db, provider)
    provider = prepared.provider
    stream = prepared.stream
    full_response = ""

    if provider.transport == "codex_cli":
        full_response = str(stream)
        for start in range(0, len(full_response), 256):
            text = full_response[start : start + 256]
            yield {"event": "token", "data": json.dumps({"text": text})}
    elif provider.transport == "responses":
        async for event in stream:
            if getattr(event, "type", "") != "response.output_text.delta":
                continue
            text = getattr(event, "delta", "")
            if text:
                full_response += text
                yield {"event": "token", "data": json.dumps({"text": text})}
    else:
        async for chunk in stream:
            delta = chunk.choices[0].delta
            if delta.content:
                full_response += delta.content
                token_data = json.dumps({"text": delta.content})
                yield {"event": "token", "data": token_data}

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
                    "source_id": c.source_id,
                    "citation_ref": c.citation_ref,
                    "reference_number": ref,
                }
            )

    if citations:
        cite_data = json.dumps({"citations": citations})
        yield {"event": "citations", "data": cite_data}

    avg_score = sum(c.score for c in chunks) / len(chunks) if chunks else 0
    done_data = json.dumps(
        {
            "grounded": bool(citations),
            "confidence": round(avg_score, 2),
        }
    )
    yield {"event": "done", "data": done_data}
