import json
from collections.abc import AsyncGenerator

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sse_starlette.sse import EventSourceResponse

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.chat import ChatRequest
from app.services.llm import stream_rag_response
from app.services.retrieval import build_context, retrieve

router = APIRouter(prefix="/chat", tags=["chat"])


async def _encode_sse(events: AsyncGenerator[dict[str, str], None]) -> AsyncGenerator[bytes, None]:
    async for event in events:
        yield f"event: {event['event']}\r\ndata: {event['data']}\r\n\r\n".encode()


def _event_stream(events: AsyncGenerator[dict[str, str], None]) -> EventSourceResponse:
    # Yield pre-framed bytes so the browser-facing proxy keeps the exact event
    # format, while EventSourceResponse supplies idle heartbeats and the SSE
    # cache, connection, and proxy-buffering headers.
    return EventSourceResponse(_encode_sse(events), media_type="text/event-stream")


@router.post("")
async def chat(
    chat_request: ChatRequest,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    chunks = await retrieve(
        query=chat_request.message,
        user_id=user.id,
        db=db,
        module_id=chat_request.module_id,
    )

    if not chunks:

        async def no_results() -> AsyncGenerator[dict[str, str], None]:
            yield {
                "event": "done",
                "data": json.dumps(
                    {
                        "grounded": False,
                        "confidence": 0,
                        "message": "No relevant content found in your workspace sources.",
                    }
                ),
            }

        return _event_stream(no_results())

    context = build_context(chunks)

    return _event_stream(
        stream_rag_response(
            query=chat_request.message,
            context=context,
            chunks=chunks,
            history=chat_request.history,
        )
    )
