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

        async def no_results() -> AsyncGenerator[str, None]:
            yield (
                "event: done\ndata: "
                + json.dumps(
                    {
                        "grounded": False,
                        "confidence": 0,
                        "message": "No relevant content found in your Canvas modules.",
                    }
                )
                + "\n\n"
            )

        return EventSourceResponse(no_results(), media_type="text/event-stream")

    context = build_context(chunks)

    return EventSourceResponse(
        stream_rag_response(
            query=chat_request.message,
            context=context,
            chunks=chunks,
            history=chat_request.history,
        ),
        media_type="text/event-stream",
    )
