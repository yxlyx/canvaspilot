from app.services.retrieval import RetrievedChunk, build_context


class TestBuildContext:
    def test_empty(self):
        assert build_context([]) == ""

    def test_single_chunk(self):
        chunk = RetrievedChunk(
            content="Assignment due Friday",
            score=0.85,
            source_title="CS2103T Assignment 1",
            source_url="http://example.com",
            source_type="assignment",
        )
        result = build_context([chunk])
        assert "[1]" in result
        assert "CS2103T Assignment 1" in result
        assert "Assignment due Friday" in result

    def test_multiple_chunks(self):
        chunks = [
            RetrievedChunk(
                content="Content A",
                score=0.9,
                source_title="Source A",
                source_url="http://a.com",
                source_type="announcement",
            ),
            RetrievedChunk(
                content="Content B",
                score=0.8,
                source_title="Source B",
                source_url="http://b.com",
                source_type="assignment",
            ),
        ]
        result = build_context(chunks)
        assert "[1]" in result
        assert "[2]" in result
        assert "Source A" in result
        assert "Source B" in result
