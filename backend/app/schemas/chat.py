import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

MAX_CHAT_MESSAGE_CHARS = 8_000
MAX_CHAT_HISTORY_MESSAGES = 40
MAX_CITATIONS_PER_MESSAGE = 20


class Citation(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(max_length=1_000)
    url: str = Field(max_length=2_048)
    snippet: str = Field(max_length=2_000)
    source_id: str | None = Field(default=None, max_length=64)
    citation_ref: str | None = Field(default=None, max_length=1_000)
    reference_number: int | None = Field(default=None, ge=1, le=100)


class ChatMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=MAX_CHAT_MESSAGE_CHARS)
    citations: list[Citation] | None = Field(default=None, max_length=MAX_CITATIONS_PER_MESSAGE)


class ChatRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    module_id: uuid.UUID | None = None
    enrollment_id: uuid.UUID | None = None
    message: str = Field(min_length=1, max_length=MAX_CHAT_MESSAGE_CHARS)
    history: list[ChatMessage] = Field(default_factory=list, max_length=MAX_CHAT_HISTORY_MESSAGES)

    @model_validator(mode="after")
    def one_scope(self):
        if self.module_id is not None and self.enrollment_id is not None:
            raise ValueError("choose either an enrollment or a legacy module scope")
        return self
