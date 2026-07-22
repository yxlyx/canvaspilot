import base64
import re
from collections.abc import Iterator
from dataclasses import dataclass
from io import BytesIO

from app.models.source import Source, SourceKind
from app.schemas.source_imports import SourceImportItem, SourceImportSection, SourceParseItem

MAX_PDF_BYTES = 10 * 1024 * 1024
MAX_PDF_PAGES = 200
MAX_PDF_TEXT_CHARS = 2_000_000


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


def parse_pdf(content_base64: str | None) -> list[SourceImportSection]:
    if not content_base64:
        raise SourceParseError("PDF content is required")
    try:
        pdf_bytes = base64.b64decode(content_base64, validate=True)
    except ValueError as exc:
        raise SourceParseError("PDF content must be base64 encoded") from exc

    if len(pdf_bytes) > MAX_PDF_BYTES:
        raise SourceParseError("PDF exceeds the 10 MiB decoded size limit")
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

    if source.source_type in (SourceKind.LINK, SourceKind.REPOSITORY):
        return SourceImportItem(source_id=source.id, metadata_only=True)

    raise SourceParseError(f"Unsupported source type: {source.source_type}")
