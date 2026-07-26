import json

import pytest

from app.schemas.chat import ChatMessage
from app.services import llm
from app.services.providers import GenerationProvider
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
async def test_generate_json_text_requests_structured_chat_output(monkeypatch):
    captured = None

    class Message:
        content = '{"cards":[]}'

    class Choice:
        message = Message()

    class Response:
        choices = [Choice()]

    class FakeCompletions:
        async def create(self, **kwargs):
            nonlocal captured
            captured = kwargs
            return Response()

    class FakeChat:
        completions = FakeCompletions()

    class FakeOpenAI:
        def __init__(self, api_key: str, **kwargs):
            self.chat = FakeChat()

    monkeypatch.setattr(llm, "AsyncOpenAI", FakeOpenAI)
    provider = GenerationProvider("openai", "study-model", "https://api.openai.com/v1", "key")

    schema = {"type": "object", "properties": {"cards": {"type": "array"}}}
    selected, text = await llm.generate_json_text(
        "Return JSON", "Evidence", None, None, provider, schema
    )

    assert selected == provider
    assert text == '{"cards":[]}'
    assert captured["response_format"] == {
        "type": "json_schema",
        "json_schema": {
            "name": "workspace_generation",
            "strict": True,
            "schema": schema,
        },
    }
    assert captured["temperature"] == 0.2
    assert captured["messages"][1]["content"] == "Evidence"


@pytest.mark.asyncio
async def test_generate_json_text_requests_structured_responses_output(monkeypatch):
    captured = None

    class Response:
        output_text = '{"cards":[]}'

    class FakeResponses:
        async def create(self, **kwargs):
            nonlocal captured
            captured = kwargs
            return Response()

    class FakeOpenAI:
        def __init__(self, api_key: str, **kwargs):
            self.responses = FakeResponses()

    monkeypatch.setattr(llm, "AsyncOpenAI", FakeOpenAI)
    provider = GenerationProvider(
        "chatgpt",
        "study-model",
        "https://provider.test/responses",
        "key",
        transport="responses",
    )
    schema = {"type": "object", "properties": {"cards": {"type": "array"}}}

    selected, text = await llm.generate_json_text(
        "Return JSON", "Evidence", None, None, provider, schema
    )

    assert selected == provider
    assert text == '{"cards":[]}'
    assert captured["text"]["format"] == {
        "type": "json_schema",
        "name": "workspace_generation",
        "strict": True,
        "schema": schema,
    }


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
        def __init__(self, api_key: str, **kwargs):
            self.chat = FakeChat()

    async def selected_provider(user, db):
        return GenerationProvider("openai", "gpt-4o", "https://api.openai.com/v1", "key")

    monkeypatch.setattr(llm, "resolve_generation_provider", selected_provider)
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
        def __init__(self, api_key: str, **kwargs):
            self.chat = FakeChat()

    async def selected_provider(user, db):
        return GenerationProvider("openai", "gpt-4o", "https://api.openai.com/v1", "key")

    monkeypatch.setattr(llm, "resolve_generation_provider", selected_provider)
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


@pytest.mark.asyncio
async def test_stream_rag_response_uses_chatgpt_responses_transport(monkeypatch):
    captured = None

    class Event:
        def __init__(self, event_type: str, delta: str = ""):
            self.type = event_type
            self.delta = delta

    async def response_stream():
        yield Event("response.created")
        yield Event("response.output_text.delta", "Grounded [1].")
        yield Event("response.completed")

    class FakeResponses:
        async def create(self, **kwargs):
            nonlocal captured
            captured = kwargs
            return response_stream()

    class FakeOpenAI:
        def __init__(self, api_key: str, **kwargs):
            assert api_key == "oauth-access"
            assert kwargs["base_url"] == "https://chatgpt.test/backend-api/codex"
            self.responses = FakeResponses()

    async def selected_provider(user, db):
        return GenerationProvider(
            provider="chatgpt",
            model="gpt-test-codex",
            endpoint="https://chatgpt.test/backend-api/codex",
            api_key="oauth-access",
            auth_method="oauth_code",
            account_id="acct-123",
            transport="responses",
        )

    monkeypatch.setattr(llm, "resolve_generation_provider", selected_provider)
    monkeypatch.setattr(llm, "AsyncOpenAI", FakeOpenAI)
    chunks = [
        RetrievedChunk(
            content="Verified source text",
            score=0.9,
            source_title="Local source",
            source_url="",
            source_type="file",
        )
    ]

    events = [
        event
        async for event in llm.stream_rag_response(
            query="Question",
            context="[1] Verified source text",
            chunks=chunks,
            history=[],
        )
    ]

    assert json.loads(events[0]["data"]) == {"text": "Grounded [1]."}
    assert events[1]["event"] == "citations"
    assert captured["extra_headers"] == {
        "originator": "canvaspilot",
        "chatgpt-account-id": "acct-123",
    }
    assert captured["model"] == "gpt-test-codex"
    assert "messages" not in captured
