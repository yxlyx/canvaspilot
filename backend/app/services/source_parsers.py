import base64
import binascii
import json
import re
import subprocess
import sys
from collections.abc import Iterator
from dataclasses import dataclass
from io import BytesIO

import pytesseract
from PIL import Image, UnidentifiedImageError
from pytesseract import TesseractError, TesseractNotFoundError

from app.models.source import Source, SourceKind
from app.schemas.source_imports import SourceImportItem, SourceImportSection, SourceParseItem
from app.services.resource_admission import RESOURCE_INTENSIVE_PARSER_SLOT

MAX_PDF_BYTES = 10 * 1024 * 1024
MAX_PDF_PAGES = 200
MAX_PDF_TEXT_CHARS = 2_000_000
MAX_PDF_EXPANDED_STREAM_BYTES = 8 * 1024 * 1024
MAX_PDF_PARSE_SECONDS = 15
MAX_PDF_PARSER_MEMORY_BYTES = 256 * 1024 * 1024
MAX_PDF_WORKER_OUTPUT_BYTES = MAX_PDF_TEXT_CHARS * 4 + 64 * 1024
MAX_IMAGE_BYTES = 10 * 1024 * 1024
MAX_IMAGE_PIXELS = 25_000_000
MAX_OCR_TEXT_CHARS = 2_000_000
OCR_TIMEOUT_SECONDS = 20
_RESOURCE_INTENSIVE_PARSER_SLOT = RESOURCE_INTENSIVE_PARSER_SLOT


class SourceParseError(ValueError):
    pass


@dataclass
class Heading:
    level: int
    title: str


def _normalize_text(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = [line.strip() for line in text.split("\n")]
    paragraphs: list[str] = []
    current: list[str] = []

    for line in lines:
        if not line:
            if current:
                paragraphs.append(" ".join(current))
                current = []
            continue
        current.append(line)

    if current:
        paragraphs.append(" ".join(current))

    return "\n\n".join(paragraphs).strip()


def _strip_frontmatter(content: str) -> str:
    lines = content.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        return content
    for index, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            return "\n".join(lines[index + 1 :])
    return content


def parse_markdown(content: str) -> list[SourceImportSection]:
    content = _strip_frontmatter(content)
    sections: list[SourceImportSection] = []
    headings: list[Heading] = []
    current_heading = ""
    current_lines: list[str] = []

    def flush() -> None:
        text = _normalize_text("\n".join(current_lines))
        if not text:
            return
        sections.append(
            SourceImportSection(
                content=text,
                location_label=current_heading,
            )
        )

    for raw_line in content.splitlines():
        match = re.match(r"^(#{1,6})\s+(.+?)\s*$", raw_line)
        if match:
            flush()
            level = len(match.group(1))
            title = match.group(2).strip().strip("#").strip()
            headings[:] = [heading for heading in headings if heading.level < level]
            headings.append(Heading(level=level, title=title))
            current_heading = " > ".join(heading.title for heading in headings)
            current_lines = [title]
            continue
        current_lines.append(raw_line)

    flush()
    if not sections:
        normalized = _normalize_text(content)
        if normalized:
            sections.append(SourceImportSection(content=normalized))
    if not sections:
        raise SourceParseError("No importable Markdown text found")
    return sections


def parse_plain_text(content: str) -> list[SourceImportSection]:
    normalized = _normalize_text(content)
    if not normalized:
        raise SourceParseError("No importable plain text found")
    return [SourceImportSection(content=normalized)]


def _parse_pdf_bytes(pdf_bytes: bytes) -> list[SourceImportSection]:
    sections: list[SourceImportSection] = []
    for page_index, page_text in enumerate(_extract_pdf_page_texts(pdf_bytes), 1):
        text = _normalize_text(page_text)
        if text:
            sections.append(
                SourceImportSection(
                    content=text,
                    location_label=f"Page {page_index}",
                )
            )
    if not sections:
        raise SourceParseError("No importable PDF text found")
    return sections


def _parse_pdf_isolated(pdf_bytes: bytes) -> list[SourceImportSection]:
    try:
        with RESOURCE_INTENSIVE_PARSER_SLOT:
            result = subprocess.run(
                [sys.executable, "-m", "app.services.pdf_parser_worker"],
                input=pdf_bytes,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=MAX_PDF_PARSE_SECONDS,
                check=False,
            )
    except subprocess.TimeoutExpired as exc:
        raise SourceParseError("PDF parsing exceeded the 15 second limit") from exc
    except OSError as exc:
        raise SourceParseError("PDF parser could not be started safely") from exc
    if result.returncode != 0 or len(result.stdout) > MAX_PDF_WORKER_OUTPUT_BYTES:
        raise SourceParseError("PDF could not be parsed within safe resource limits")
    try:
        payload = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SourceParseError("PDF parser returned an invalid result") from exc
    if not isinstance(payload, dict):
        raise SourceParseError("PDF parser returned an invalid result")
    error = payload.get("error")
    if isinstance(error, str):
        raise SourceParseError(error)
    raw_sections = payload.get("sections")
    if not isinstance(raw_sections, list):
        raise SourceParseError("PDF parser returned an invalid result")
    try:
        return [SourceImportSection.model_validate(item) for item in raw_sections]
    except (TypeError, ValueError) as exc:
        raise SourceParseError("PDF parser returned an invalid result") from exc


def parse_pdf(content_base64: str | None) -> list[SourceImportSection]:
    if not content_base64:
        raise SourceParseError("PDF content is required")
    try:
        pdf_bytes = base64.b64decode(content_base64, validate=True)
    except ValueError as exc:
        raise SourceParseError("PDF content must be base64 encoded") from exc

    if len(pdf_bytes) > MAX_PDF_BYTES:
        raise SourceParseError("PDF exceeds the 10 MiB decoded size limit")
    return _parse_pdf_isolated(pdf_bytes)


def parse_image(
    content_base64: str | None,
    filename: str | None,
) -> list[SourceImportSection]:
    with RESOURCE_INTENSIVE_PARSER_SLOT:
        return _parse_image(content_base64, filename)


def _parse_image(
    content_base64: str | None,
    filename: str | None,
) -> list[SourceImportSection]:
    if not content_base64 or not filename:
        raise SourceParseError("Image content and filename are required")
    try:
        image_bytes = base64.b64decode(content_base64, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise SourceParseError("Image content must be base64 encoded") from exc
    if not image_bytes:
        raise SourceParseError("Image file is empty")
    if len(image_bytes) > MAX_IMAGE_BYTES:
        raise SourceParseError("Image exceeds the 10 MiB decoded size limit")

    try:
        Image.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS
        with Image.open(BytesIO(image_bytes)) as image:
            if image.format not in {"PNG", "JPEG"}:
                raise SourceParseError("Only PNG and JPEG images are supported")
            width, height = image.size
            if width < 1 or height < 1:
                raise SourceParseError("Image dimensions are invalid")
            if width * height > MAX_IMAGE_PIXELS:
                raise SourceParseError("Image exceeds the 25 megapixel OCR limit")
            image.load()
            prepared = image.convert("RGB")
            text = pytesseract.image_to_string(
                prepared,
                lang="eng",
                config="--psm 3",
                timeout=OCR_TIMEOUT_SECONDS,
            )
    except SourceParseError:
        raise
    except (UnidentifiedImageError, Image.DecompressionBombError) as exc:
        raise SourceParseError("Image could not be decoded safely") from exc
    except TesseractNotFoundError as exc:
        raise SourceParseError("Image OCR is not available on this server") from exc
    except TesseractError as exc:
        raise SourceParseError("Image could not be read by OCR") from exc
    except RuntimeError as exc:
        raise SourceParseError("Image OCR timed out") from exc

    text = _normalize_text(text)
    if not text:
        raise SourceParseError("No readable text found in image")
    if len(text) > MAX_OCR_TEXT_CHARS:
        raise SourceParseError("Image OCR text exceeds 2,000,000 characters")
    return [SourceImportSection(content=text, location_label="Image OCR")]


def _extract_pdf_page_texts(pdf_bytes: bytes) -> Iterator[str]:
    from pypdf import PdfReader

    try:
        reader = PdfReader(BytesIO(pdf_bytes), strict=True)
        if len(reader.pages) > MAX_PDF_PAGES:
            raise SourceParseError("PDF exceeds the 200 page limit")
        total_text = 0
        for page in reader.pages:
            page_text = page.extract_text() or ""
            total_text += len(_normalize_text(page_text))
            if total_text > MAX_PDF_TEXT_CHARS:
                raise SourceParseError("PDF extracted text exceeds 2,000,000 characters")
            yield page_text
    except SourceParseError:
        raise
    except Exception as exc:
        raise SourceParseError("PDF could not be parsed safely") from exc


def parse_source_payload(source: Source, payload: SourceParseItem) -> SourceImportItem:
    if source.source_type == SourceKind.MARKDOWN:
        if payload.content is None:
            raise SourceParseError("Markdown content is required")
        return SourceImportItem(source_id=source.id, sections=parse_markdown(payload.content))

    if source.source_type == SourceKind.PLAIN_TEXT:
        if payload.content is None:
            raise SourceParseError("Plain text content is required")
        return SourceImportItem(source_id=source.id, sections=parse_plain_text(payload.content))

    if source.source_type == SourceKind.PDF:
        return SourceImportItem(source_id=source.id, sections=parse_pdf(payload.content_base64))

    if source.source_type == SourceKind.IMAGE:
        return SourceImportItem(
            source_id=source.id,
            sections=parse_image(payload.content_base64, payload.filename),
        )

    if source.source_type in (SourceKind.LINK, SourceKind.REPOSITORY):
        return SourceImportItem(source_id=source.id, metadata_only=True)

    raise SourceParseError(f"Unsupported source type: {source.source_type}")
