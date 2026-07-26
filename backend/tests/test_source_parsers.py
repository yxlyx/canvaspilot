import base64
import uuid
from io import BytesIO

import pytest
from PIL import Image

from app.models.source import Source, SourceKind
from app.schemas.source_imports import SourceParseItem
from app.services import source_parsers
from app.services.source_parsers import (
    SourceParseError,
    parse_image,
    parse_markdown,
    parse_pdf,
    parse_plain_text,
    parse_source_payload,
)


def _encoded_image(image_format: str = "PNG") -> str:
    output = BytesIO()
    Image.new("RGB", (120, 60), "white").save(output, format=image_format)
    return base64.b64encode(output.getvalue()).decode()


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


def test_parse_image_extracts_ocr_text_with_location(monkeypatch):
    monkeypatch.setattr(
        source_parsers.pytesseract,
        "image_to_string",
        lambda image, **kwargs: "Binary search trees preserve ordering.",
    )

    sections = parse_image(_encoded_image(), "lecture.png")

    assert len(sections) == 1
    assert sections[0].location_label == "Image OCR"
    assert sections[0].content == "Binary search trees preserve ordering."


def test_parse_image_rejects_non_png_or_jpeg(monkeypatch):
    monkeypatch.setattr(
        source_parsers.pytesseract,
        "image_to_string",
        lambda image, **kwargs: "text",
    )

    with pytest.raises(SourceParseError, match="Only PNG and JPEG"):
        parse_image(_encoded_image("GIF"), "lecture.gif")


def test_parse_image_enforces_pixel_limit(monkeypatch):
    monkeypatch.setattr(source_parsers, "MAX_IMAGE_PIXELS", 100)

    with pytest.raises(SourceParseError, match="decoded safely|25 megapixel OCR limit"):
        parse_image(_encoded_image(), "lecture.png")


def test_parse_image_reports_ocr_timeout(monkeypatch):
    def timeout(*_args, **_kwargs):
        raise RuntimeError("Tesseract process timeout")

    monkeypatch.setattr(source_parsers.pytesseract, "image_to_string", timeout)

    with pytest.raises(SourceParseError, match="OCR timed out"):
        parse_image(_encoded_image(), "lecture.png")


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
