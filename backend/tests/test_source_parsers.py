import base64
import uuid

import pytest

from app.models.source import Source, SourceKind
from app.schemas.source_imports import SourceParseItem
from app.services.source_parsers import (
    SourceParseError,
    parse_markdown,
    parse_pdf,
    parse_plain_text,
    parse_source_payload,
)


def _minimal_pdf_base64(text: str) -> str:
    stream = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET\n".encode()
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"endstream",
    ]
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f"{index} 0 obj\n".encode())
        pdf.extend(body)
        pdf.extend(b"\nendobj\n")
    xref_offset = len(pdf)
    pdf.extend(f"xref\n0 {len(objects) + 1}\n".encode())
    pdf.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        pdf.extend(f"{offset:010d} 00000 n \n".encode())
    pdf.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF\n".encode()
    )
    return base64.b64encode(bytes(pdf)).decode()


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


def test_parse_pdf_extracts_page_labels():
    pytest.importorskip("pypdf")

    sections = parse_pdf(_minimal_pdf_base64("Limits PDF page"))

    assert len(sections) == 1
    assert sections[0].location_label == "Page 1"
    assert "Limits PDF page" in sections[0].content


def test_parse_pdf_rejects_invalid_base64():
    pytest.importorskip("pypdf")

    with pytest.raises(SourceParseError, match="base64"):
        parse_pdf("not base64")


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
