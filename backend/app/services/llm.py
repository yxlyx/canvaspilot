import json
import logging
import re
from collections.abc import AsyncGenerator
from dataclasses import dataclass
from typing import Any

from openai import (
    APIConnectionError,
    APIStatusError,
    APITimeoutError,
    AsyncAzureOpenAI,
    AsyncOpenAI,
    AuthenticationError,
    RateLimitError,
)
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

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = (
    "You are WikiBase, an academic study helper for NUS students. "
    "Answer the user conversationally and helpfully. Use the provided workspace "
    "source context when it is relevant, and use general knowledge when the sources "
    "do not contain enough information.\n\n"
    "Rules:\n"
    "- Cite workspace sources using [1], [2] etc. matching the context numbers\n"
    "- Never attach a workspace citation to a claim that the source does not support\n"
    "- If you combine source material with general knowledge, make the distinction clear\n"
    "- If no relevant source context is provided, answer normally without citations\n"
    "- Be concise and accurate\n"
    "- Do not invent sources, quotations, or citations\n\n"
    "Context:\n{context}"
)


@dataclass(frozen=True)
class PreparedRagStream:
    provider: GenerationProvider
    stream: Any


def _provider_client(provider, *, timeout: float | None = None):
    client_options = {} if timeout is None else {"timeout": timeout}
    if provider.provider == "azure_openai":
        return AsyncAzureOpenAI(
            api_key=provider.api_key,
            azure_endpoint=provider.endpoint,
            api_version="2024-10-21",
            **client_options,
        )
    return AsyncOpenAI(
        api_key=provider.api_key,
        base_url=provider.endpoint,
        **client_options,
    )


def _response_text(response: Any) -> str:
    output_text = getattr(response, "output_text", None)
    if isinstance(output_text, str):
        return output_text.strip()
    choices = getattr(response, "choices", None)
    if choices:
        content = getattr(choices[0].message, "content", None)
        if isinstance(content, str):
            return content.strip()
    return ""


def _chat_response_format(
    provider: GenerationProvider,
    json_schema: dict[str, Any] | None,
) -> dict[str, Any]:
    if json_schema is None or provider.provider == "codegraff":
        return {"type": "json_object"}
    return {
        "type": "json_schema",
        "json_schema": {
            "name": "workspace_generation",
            "strict": True,
            "schema": json_schema,
        },
    }


def _sanitized_upstream_error(exc: APIStatusError) -> str:
    values: list[str] = []
    try:
        payload = exc.response.json()
        error = payload.get("error", payload) if isinstance(payload, dict) else {}
        if isinstance(error, dict):
            for field in ("type", "code", "message"):
                value = error.get(field)
                if isinstance(value, (str, int)) and str(value).strip():
                    values.append(f"{field}={value}")
    except (AttributeError, TypeError, ValueError):
        pass
    summary = " ".join(values) or "no structured upstream detail"
    summary = re.sub(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer [redacted]", summary)
    summary = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "[redacted]", summary)
    summary = re.sub(
        r"(?i)\b(api[_ -]?key|access[_ -]?token|credential)\b(\s*[:=]?\s*)\S+",
        r"\1\2[redacted]",
        summary,
    )
    return re.sub(r"[\r\n\t]+", " ", summary)[:500]


def _provider_error(
    provider: GenerationProvider,
    exc: Exception,
    operation: str,
) -> WikiBaseError:
    status = getattr(exc, "status_code", None)
    if isinstance(exc, APIStatusError):
        logger.warning(
            "Provider request failed provider=%s model=%s operation=%s status=%s upstream=%s",
            provider.provider,
            provider.model,
            operation,
            status,
            _sanitized_upstream_error(exc),
        )
    else:
        logger.warning(
            "Provider request failed provider=%s model=%s operation=%s error=%s",
            provider.provider,
            provider.model,
            operation,
            type(exc).__name__,
        )
    if isinstance(exc, AuthenticationError) or status in {401, 403}:
        return WikiBaseError(
            409,
            "provider_authentication_failed",
            "Reconnect the selected answer provider before generating workspace content",
        )
    if isinstance(exc, RateLimitError) or status == 429:
        return WikiBaseError(
            429,
            "provider_rate_limited",
            "The answer provider is busy or has reached its usage limit",
        )
    if isinstance(exc, APITimeoutError):
        return WikiBaseError(
            504,
            "provider_timeout",
            "The answer provider took too long to respond",
        )
    if isinstance(exc, APIConnectionError):
        return WikiBaseError(
            502,
            "provider_unavailable",
            "The answer provider could not be reached",
        )
    if isinstance(status, int) and 400 <= status < 500:
        return WikiBaseError(
            502,
            "provider_request_rejected",
            "The answer provider rejected the generation request",
        )
    return WikiBaseError(
        502,
        "provider_unavailable",
        "The answer provider could not complete the generation request",
    )


async def probe_generation_provider(provider: GenerationProvider) -> None:
    client = _provider_client(provider, timeout=15)
    try:
        if provider.transport == "responses":
            headers = {"originator": "canvaspilot"}
            if provider.account_id:
                headers["chatgpt-account-id"] = provider.account_id
            response = await client.responses.create(
                model=provider.model,
                input="Reply with only OK.",
                max_output_tokens=128,
                extra_headers=headers,
            )
        else:
            messages = [{"role": "user", "content": "Reply with only OK."}]
            options: dict[str, Any] = {}
            if provider.provider == "codegraff":
                messages = [
                    {"role": "system", "content": "Return only one JSON object."},
                    {"role": "user", "content": 'Return {"ok":true}.'},
                ]
                options["response_format"] = {"type": "json_object"}
            response = await client.chat.completions.create(
                model=provider.model,
                messages=messages,
                max_tokens=128,
                **options,
            )
    except (
        AuthenticationError,
        RateLimitError,
        APITimeoutError,
        APIConnectionError,
        APIStatusError,
    ) as exc:
        raise _provider_error(provider, exc, "connection test") from exc
    text = _response_text(response)
    if not text:
        raise WikiBaseError(
            502,
            "provider_invalid_response",
            "The answer provider completed the test without returning text",
        )
    if provider.provider == "codegraff":
        try:
            payload = json.loads(text)
        except (TypeError, ValueError) as exc:
            raise WikiBaseError(
                502,
                "provider_invalid_response",
                "Codegraff completed the test without returning valid JSON",
            ) from exc
        if not isinstance(payload, dict) or payload.get("ok") is not True:
            raise WikiBaseError(
                502,
                "provider_invalid_response",
                "Codegraff completed the test without returning the expected JSON",
            )


async def generate_json_text(
    system_prompt: str,
    user_prompt: str,
    user: User | None,
    db: AsyncSession | None,
    provider: GenerationProvider,
    json_schema: dict[str, Any] | None = None,
) -> tuple[GenerationProvider, str]:
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]
    structured_format = (
        {
            "type": "json_schema",
            "name": "workspace_generation",
            "strict": True,
            "schema": json_schema,
        }
        if json_schema is not None
        else {"type": "json_object"}
    )
    chat_format = _chat_response_format(provider, json_schema)
    try:
        if provider.transport == "codex_cli":
            from app.services.local_codex import generate_with_local_codex

            transcript = "\n\n".join(
                f"{message['role'].upper()}:\n{message['content']}" for message in messages
            )
            try:
                text = await generate_with_local_codex(
                    "Return only the requested JSON object. Do not inspect local files, "
                    "run commands, or use tools.\n\n" + transcript,
                    provider.model,
                )
            except WikiBaseError as exc:
                await mark_local_codex_unavailable(user, db, exc.error, exc.detail)
                raise
            return provider, text.strip()

        client = _provider_client(provider)
        if provider.transport == "responses":
            headers = {"originator": "canvaspilot"}
            if provider.account_id:
                headers["chatgpt-account-id"] = provider.account_id
            try:
                response = await client.responses.create(
                    model=provider.model,
                    input=messages,
                    max_output_tokens=4096,
                    text={"format": structured_format},
                    extra_headers=headers,
                )
            except AuthenticationError:
                provider = await force_refresh_generation_provider(user, db)
                client = _provider_client(provider)
                headers = {"originator": "canvaspilot"}
                if provider.account_id:
                    headers["chatgpt-account-id"] = provider.account_id
                response = await client.responses.create(
                    model=provider.model,
                    input=messages,
                    max_output_tokens=4096,
                    text={"format": structured_format},
                    extra_headers=headers,
                )
        else:
            response = await client.chat.completions.create(
                model=provider.model,
                messages=messages,
                response_format=chat_format,
                temperature=0.2,
                max_tokens=4096,
            )
    except (
        AuthenticationError,
        RateLimitError,
        APITimeoutError,
        APIConnectionError,
        APIStatusError,
    ) as exc:
        raise _provider_error(provider, exc, "structured generation") from exc

    text = _response_text(response)
    if not text:
        raise WikiBaseError(
            502,
            "provider_invalid_response",
            "The answer provider returned no generated content",
        )
    return provider, text


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
    try:
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
    except (
        AuthenticationError,
        RateLimitError,
        APITimeoutError,
        APIConnectionError,
        APIStatusError,
    ) as exc:
        raise _provider_error(provider, exc, "grounded answer") from exc
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
