from app.models.content import SourceType
from app.services import ingestion
from app.services.ingestion import ChunkMeta, chunk_text, parse_html


class TestParseHtml:
    def test_strips_scripts(self):
        html = "<p>Hello</p><script>alert(1)</script>"
        assert parse_html(html) == "Hello"

    def test_preserves_inline_formatting(self):
        html = "<p>This is <strong>bold</strong> text.</p>"
        assert parse_html(html) == "This is bold text."

    def test_separates_block_elements(self):
        html = "<p>First paragraph</p><p>Second paragraph</p>"
        result = parse_html(html)
        assert "First paragraph" in result
        assert "Second paragraph" in result
        assert "\n" in result

    def test_replaces_iframes(self):
        html = '<iframe src="https://example.com/tool"></iframe>'
        result = parse_html(html)
        assert "[External tool: https://example.com/tool]" in result

    def test_replaces_images(self):
        html = '<img alt="diagram" src="test.png">'
        result = parse_html(html)
        assert "[Image: diagram]" in result

    def test_empty_input(self):
        assert parse_html("") == ""
        assert parse_html(None) == ""

    def test_handles_br_tags(self):
        html = "Line 1<br>Line 2"
        result = parse_html(html)
        assert "Line 1" in result
        assert "Line 2" in result

    def test_strips_nav_and_style(self):
        html = "<nav>Menu</nav><style>.x{}</style><p>Content</p>"
        assert parse_html(html) == "Content"


class TestChunkText:
    def _meta(self):
        return ChunkMeta(
            module_id="mod1",
            source_type=SourceType.ANNOUNCEMENT,
            source_id="a1",
            source_title="Test",
            source_url="http://example.com",
        )

    def test_short_text_single_chunk(self):
        chunks = chunk_text("Hello world. This is a test.", self._meta())
        assert len(chunks) == 1
        assert chunks[0].content == "Hello world. This is a test."

    def test_empty_text(self):
        assert chunk_text("", self._meta()) == []
        assert chunk_text("   ", self._meta()) == []

    def test_preserves_metadata(self):
        chunks = chunk_text("Some content here.", self._meta())
        assert chunks[0].meta.source_type == SourceType.ANNOUNCEMENT
        assert chunks[0].meta.module_id == "mod1"

    def test_token_count_positive(self):
        chunks = chunk_text("Hello world.", self._meta())
        assert chunks[0].token_count > 0

    def test_long_text_splits(self):
        long_text = ". ".join(f"Sentence number {i} with some padding words" for i in range(200))
        chunks = chunk_text(long_text, self._meta())
        assert len(chunks) > 1
        for chunk in chunks:
            assert chunk.token_count <= 520  # small margin for boundary effects

    def test_chunking_has_a_deterministic_offline_fallback(self, monkeypatch):
        monkeypatch.setattr(ingestion, "_encoding", None)
        monkeypatch.setattr(
            ingestion.tiktoken,
            "get_encoding",
            lambda _name: (_ for _ in ()).throw(ConnectionError("offline")),
        )

        chunks = chunk_text("Offline tokenization remains available.", self._meta())

        assert len(chunks) == 1
        assert chunks[0].token_count == len(chunks[0].content)
        monkeypatch.setattr(ingestion, "_encoding", None)
