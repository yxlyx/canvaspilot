import json

import pytest

from app.schemas.chat import ChatMessage
from app.services import llm
from app.services.retrieval import RetrievedChunk


class FakeDelta:
    def __init__(self, content: str):
        self.content = content


class FakeChoice:
    def __init__(self, content: str):
        self.delta = FakeDelta(content)


class FakeStreamChunk:
    def __init__(self, content: str):
        self.choices = [FakeChoice(content)]


async def fake_stream(parts: list[str]):
    for part in parts:
        yield FakeStreamChunk(part)


@pytest.mark.asyncio
async def test_stream_rag_response_formats_events_and_citations(settings, monkeypatch):
    captured_messages = None

    class FakeCompletions:
        async def create(self, **kwargs):
            nonlocal captured_messages
            captured_messages = kwargs["messages"]
            return fake_stream(["Read ", "source [1]."])

    class FakeChat:
        completions = FakeCompletions()

    class FakeOpenAI:
        def __init__(self, api_key: str):
            self.chat = FakeChat()

    monkeypatch.setattr(llm, "get_settings", lambda: settings)
    monkeypatch.setattr(llm, "AsyncOpenAI", FakeOpenAI)

    chunks = [
        RetrievedChunk(
            content="Assignment due Friday",
            score=0.8,
            source_title="Assignment 1",
            source_url="https://canvas.example/a1",
            source_type="assignment",
        )
    ]

    events = [
        event
        async for event in llm.stream_rag_response(
            query="When is it due?",
            context="[1] Assignment due Friday",
            chunks=chunks,
            history=[ChatMessage(role="assistant", content="Previous answer")],
        )
    ]

    assert events[0]["event"] == "token"
    assert json.loads(events[0]["data"]) == {"text": "Read "}
    assert events[1]["event"] == "token"
    assert events[2]["event"] == "citations"
    assert json.loads(events[2]["data"])["citations"][0]["title"] == "Assignment 1"
    assert json.loads(events[3]["data"]) == {"grounded": True, "confidence": 0.8}
    assert captured_messages[-2]["content"] == "Previous answer"


@pytest.mark.asyncio
async def test_stream_rag_response_done_without_citations(settings, monkeypatch):
    class FakeCompletions:
        async def create(self, **kwargs):
            return fake_stream(["I don't have enough information."])

    class FakeChat:
        completions = FakeCompletions()

    class FakeOpenAI:
        def __init__(self, api_key: str):
            self.chat = FakeChat()

    monkeypatch.setattr(llm, "get_settings", lambda: settings)
    monkeypatch.setattr(llm, "AsyncOpenAI", FakeOpenAI)

    events = [
        event
        async for event in llm.stream_rag_response(
            query="Question",
            context="",
            chunks=[],
            history=[],
        )
    ]

    assert not any(event["event"] == "citations" for event in events)
    assert json.loads(events[-1]["data"]) == {"grounded": False, "confidence": 0}
