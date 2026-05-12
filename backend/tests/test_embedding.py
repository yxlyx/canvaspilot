import pytest

from app.models.content import ContentChunk, SourceType
from app.services import embedding


class DummyDB:
    def __init__(self):
        self.commits = 0

    async def commit(self):
        self.commits += 1


class FakeEmbeddingData:
    def __init__(self, value: float):
        self.embedding = [value] * 1536


class FakeEmbeddingResponse:
    def __init__(self, count: int):
        self.data = [FakeEmbeddingData(float(i)) for i in range(count)]


def make_chunk(idx: int) -> ContentChunk:
    return ContentChunk(
        module_id="00000000-0000-0000-0000-000000000001",
        source_type=SourceType.PAGE,
        source_id=str(idx),
        source_title=f"Source {idx}",
        content=f"Content {idx}",
        token_count=2,
    )


@pytest.mark.asyncio
async def test_embed_chunks_batches_and_commits(settings, monkeypatch):
    calls: list[list[str]] = []

    class FakeEmbeddings:
        async def create(self, model: str, input: list[str]):
            assert model == embedding.MODEL
            calls.append(input)
            return FakeEmbeddingResponse(len(input))

    class FakeOpenAI:
        def __init__(self, api_key: str):
            assert api_key == settings.openai_api_key
            self.embeddings = FakeEmbeddings()

    monkeypatch.setattr(embedding, "get_settings", lambda: settings)
    monkeypatch.setattr(embedding, "AsyncOpenAI", FakeOpenAI)

    chunks = [make_chunk(i) for i in range(101)]
    db = DummyDB()

    await embedding.embed_chunks(chunks, db)

    assert [len(call) for call in calls] == [100, 1]
    assert len(chunks[0].embedding) == 1536
    assert db.commits == 1


@pytest.mark.asyncio
async def test_embed_chunks_retries(settings, monkeypatch):
    attempts = 0

    class FakeEmbeddings:
        async def create(self, model: str, input: list[str]):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise RuntimeError("temporary failure")
            return FakeEmbeddingResponse(len(input))

    class FakeOpenAI:
        def __init__(self, api_key: str):
            self.embeddings = FakeEmbeddings()

    async def fake_sleep(seconds: float):
        assert seconds == 1

    monkeypatch.setattr(embedding, "get_settings", lambda: settings)
    monkeypatch.setattr(embedding, "AsyncOpenAI", FakeOpenAI)
    monkeypatch.setattr(embedding.asyncio, "sleep", fake_sleep)

    chunks = [make_chunk(1)]
    await embedding.embed_chunks(chunks, DummyDB())

    assert attempts == 2
    assert len(chunks[0].embedding) == 1536


@pytest.mark.asyncio
async def test_embed_query(settings, monkeypatch):
    class FakeEmbeddings:
        async def create(self, model: str, input: list[str]):
            assert input == ["when is the exam?"]
            return FakeEmbeddingResponse(1)

    class FakeOpenAI:
        def __init__(self, api_key: str):
            self.embeddings = FakeEmbeddings()

    monkeypatch.setattr(embedding, "get_settings", lambda: settings)
    monkeypatch.setattr(embedding, "AsyncOpenAI", FakeOpenAI)

    result = await embedding.embed_query("when is the exam?")

    assert len(result) == 1536
