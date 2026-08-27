import base64
from io import BytesIO

import pytest
from PIL import Image
from pypdf import PdfWriter

from app.models.processing import SourceVersion
from app.models.source import SourceKind
from app.services.source_previews import (
    MAX_PREVIEW_BASE64_CHARS,
    SourcePreviewUnavailableError,
    SourcePreviewUnsupportedError,
    render_source_preview,
)


def _source(kind: SourceKind) -> SourceKind:
    return kind


def _version(payload: dict) -> SourceVersion:
    return SourceVersion(payload=payload)


def test_pdf_preview_rasterizes_only_a_bounded_first_page():
    document = PdfWriter()
    document.add_blank_page(width=612, height=792)
    document.add_blank_page(width=2000, height=100)
    raw = BytesIO()
    document.write(raw)

    preview = render_source_preview(
        _source(SourceKind.PDF),
        _version({"content_base64": base64.b64encode(raw.getvalue()).decode()}),
    )

    assert preview.startswith(b"\x89PNG\r\n\x1a\n")
    with Image.open(BytesIO(preview)) as image:
        assert image.width <= 900
        assert image.height <= 1160
        assert image.height > image.width


def test_text_preview_contains_real_source_content_pixels():
    preview = render_source_preview(
        _source(SourceKind.MARKDOWN),
        _version({"content": "# Actual lecture notes\n\nThe first page discusses balanced trees."}),
    )

    with Image.open(BytesIO(preview)) as image:
        assert image.size == (900, 1160)
        colors = image.getcolors(maxcolors=1_000_000)
        assert colors is not None
        assert len(colors) > 1


def test_preview_rejects_oversized_base64_before_decoding():
    with pytest.raises(SourcePreviewUnsupportedError):
        render_source_preview(
            _source(SourceKind.PDF),
            _version({"content_base64": "A" * (MAX_PREVIEW_BASE64_CHARS + 1)}),
        )


def test_preview_reports_malformed_native_content_as_temporarily_unavailable():
    malformed = base64.b64encode(b"not a PDF").decode()
    with pytest.raises(SourcePreviewUnavailableError):
        render_source_preview(
            _source(SourceKind.PDF),
            _version({"content_base64": malformed}),
        )
