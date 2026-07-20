import base64
import uuid

import pytest

from app.models.source import Source, SourceKind
from app.schemas.source_imports import SourceParseItem
from app.services import source_parsers
from app.services.source_parsers import (
    SourceParseError,
    parse_markdown,
    parse_pdf,
    parse_plain_text,
    parse_source_payload,
)


def test_parse_markdown_strips_frontmatter_and_tracks_headings():
    sections = parse_markdown(
        """---
title: Hidden
---
# Limits
Limits describe behavior.

## Continuity
Continuity matches the function value.
"""
    )

    assert [section.location_label for section in sections] == [
        "Limits",
        "Limits > Continuity",
    ]
    assert "title: Hidden" not in sections[0].content
    assert "Limits describe behavior." in sections[0].content


def test_parse_plain_text_normalizes_paragraphs():
    sections = parse_plain_text(" First line\r\n second line\n\nThird line ")

    assert len(sections) == 1
    assert sections[0].content == "First line second line\n\nThird line"


def test_parse_pdf_extracts_page_labels(monkeypatch):
    def fake_extract(pdf_bytes: bytes) -> list[str]:
        assert pdf_bytes == b"pdf-bytes"
        return ["Limits PDF page", ""]

    monkeypatch.setattr(source_parsers, "_extract_pdf_page_texts", fake_extract)

    sections = parse_pdf(base64.b64encode(b"pdf-bytes").decode())

    assert len(sections) == 1
    assert sections[0].location_label == "Page 1"
    assert "Limits PDF page" in sections[0].content


def test_parse_pdf_rejects_invalid_base64():
    with pytest.raises(SourceParseError, match="base64"):
        parse_pdf("not base64")


def test_pdf_extracted_text_limit_stops_per_page_extraction(monkeypatch):
    extracted_pages = 0

    class Page:
        def extract_text(self):
            nonlocal extracted_pages
            extracted_pages += 1
            return "x" * 20_000

    class Reader:
        def __init__(self, *_args, **_kwargs):
            self.pages = [Page() for _ in range(200)]

    monkeypatch.setattr("pypdf.PdfReader", Reader)

    with pytest.raises(SourceParseError, match="extracted text exceeds"):
        list(source_parsers._extract_pdf_page_texts(b"pdf-bytes"))

    assert extracted_pages == 101


def test_parse_source_payload_marks_link_and_repository_metadata_only():
    for source_type in (SourceKind.LINK, SourceKind.REPOSITORY):
        source = Source(
            id=uuid.uuid4(),
            source_type=source_type,
            origin="test",
            title="Reference",
            source_url="https://example.com",
            citation_label="Reference",
            topic_tags=[],
        )

        item = parse_source_payload(source, SourceParseItem(source_id=source.id))

        assert item.metadata_only is True
        assert item.sections == []
