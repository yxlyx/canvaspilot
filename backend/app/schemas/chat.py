import uuid

from pydantic import BaseModel


class Citation(BaseModel):
    title: str
    url: str
    snippet: str


class ChatMessage(BaseModel):
    role: str
    content: str
    citations: list[Citation] | None = None


class ChatRequest(BaseModel):
    module_id: uuid.UUID | None = None
    message: str
    history: list[ChatMessage] = []
