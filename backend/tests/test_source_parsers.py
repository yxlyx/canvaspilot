import base64
import uuid
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
from threading import Event

import pytest
from PIL import Image
from pypdf import PdfWriter, filters
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

from app.models.source import Source, SourceKind
from app.schemas.source_imports import SourceParseItem
from app.services import pdf_parser_worker, source_parsers
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

    sections = source_parsers._parse_pdf_bytes(b"pdf-bytes")

    assert len(sections) == 1
    assert sections[0].location_label == "Page 1"
    assert "Limits PDF page" in sections[0].content


def test_parse_pdf_extracts_text_in_real_bounded_worker():
    writer = PdfWriter()
    page = writer.add_blank_page(width=612, height=792)
    font = DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Font"),
            NameObject("/Subtype"): NameObject("/Type1"),
            NameObject("/BaseFont"): NameObject("/Helvetica"),
        }
    )
    page[NameObject("/Resources")] = DictionaryObject(
        {NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})}
    )
    stream = DecodedStreamObject()
    stream.set_data(b"BT /F1 12 Tf 72 720 Td (Bounded PDF) Tj ET")
    page[NameObject("/Contents")] = stream.flate_encode()
    output = BytesIO()
    writer.write(output)

    sections = parse_pdf(base64.b64encode(output.getvalue()).decode())

    assert [section.content for section in sections] == ["Bounded PDF"]


def test_parse_pdf_rejects_real_oversized_expanded_stream():
    writer = PdfWriter()
    page = writer.add_blank_page(width=612, height=792)
    font = DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Font"),
            NameObject("/Subtype"): NameObject("/Type1"),
            NameObject("/BaseFont"): NameObject("/Helvetica"),
        }
    )
    page[NameObject("/Resources")] = DictionaryObject(
        {NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})}
    )
    operator = b"BT /F1 1 Tf 0 0 Td (x) Tj ET\n"
    expanded_size = source_parsers.MAX_PDF_EXPANDED_STREAM_BYTES * 6 // 5
    stream = DecodedStreamObject()
    stream.set_data(operator * (expanded_size // len(operator) + 1))
    page[NameObject("/Contents")] = stream.flate_encode()
    output = BytesIO()
    writer.write(output)
    pdf_bytes = output.getvalue()
    assert len(pdf_bytes) < source_parsers.MAX_PDF_BYTES

    with pytest.raises(SourceParseError, match="could not be parsed safely"):
        parse_pdf(base64.b64encode(pdf_bytes).decode())


def test_parse_pdf_runs_in_bounded_worker(monkeypatch):
    def fake_run(command, **kwargs):
        assert command == [source_parsers.sys.executable, "-m", "app.services.pdf_parser_worker"]
        assert kwargs["input"] == b"pdf-bytes"
        assert kwargs["timeout"] == source_parsers.MAX_PDF_PARSE_SECONDS
        return source_parsers.subprocess.CompletedProcess(
            command,
            0,
            stdout=b'{"sections":[{"content":"Bounded PDF","location_label":"Page 1"}]}',
        )

    monkeypatch.setattr(source_parsers.subprocess, "run", fake_run)

    sections = parse_pdf(base64.b64encode(b"pdf-bytes").decode())

    assert [section.content for section in sections] == ["Bounded PDF"]


def test_parse_pdf_waits_for_process_wide_parser_slot(monkeypatch):
    worker_started = Event()

    def fake_run(command, **_kwargs):
        worker_started.set()
        return source_parsers.subprocess.CompletedProcess(
            command,
            0,
            stdout=b'{"sections":[{"content":"Bounded PDF","location_label":"Page 1"}]}',
        )

    monkeypatch.setattr(source_parsers.subprocess, "run", fake_run)
    assert source_parsers._RESOURCE_INTENSIVE_PARSER_SLOT.acquire(timeout=1)
    with ThreadPoolExecutor(max_workers=1) as executor:
        try:
            future = executor.submit(parse_pdf, base64.b64encode(b"pdf-bytes").decode())
            assert not worker_started.wait(0.1)
        finally:
            source_parsers._RESOURCE_INTENSIVE_PARSER_SLOT.release()
        sections = future.result(timeout=1)

    assert worker_started.is_set()
    assert [section.content for section in sections] == ["Bounded PDF"]


def test_parse_pdf_terminates_timed_out_worker(monkeypatch):
    def time_out(command, **kwargs):
        raise source_parsers.subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr(source_parsers.subprocess, "run", time_out)

    with pytest.raises(SourceParseError, match="15 second limit"):
        parse_pdf(base64.b64encode(b"pdf-bytes").decode())


def test_pdf_worker_lowers_dependency_stream_limits():
    original = {name: getattr(filters, name) for name in pdf_parser_worker._PYPDF_LIMIT_NAMES}
    try:
        pdf_parser_worker._apply_pypdf_limits()
        assert all(
            getattr(filters, name) == source_parsers.MAX_PDF_EXPANDED_STREAM_BYTES
            for name in pdf_parser_worker._PYPDF_LIMIT_NAMES
        )
    finally:
        for name, value in original.items():
            setattr(filters, name, value)


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
