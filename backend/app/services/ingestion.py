import logging
import re
from dataclasses import dataclass
from datetime import UTC, datetime

import tiktoken
from bs4 import BeautifulSoup
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.content import ContentChunk, SourceType
from app.models.module import Announcement, Assignment, Module
from app.models.user import User
from app.services.canvas import CanvasClient, decrypt_token
from app.services.embedding import embed_chunks

logger = logging.getLogger(__name__)

_encoding = tiktoken.get_encoding("cl100k_base")

CHUNK_SIZE = 512
CHUNK_OVERLAP = 64


@dataclass
class ChunkMeta:
    module_id: str
    source_type: SourceType
    source_id: str
    source_title: str
    source_url: str


@dataclass
class TextChunk:
    content: str
    token_count: int
    meta: ChunkMeta


def parse_html(html: str) -> str:
    if not html:
        return ""
    soup = BeautifulSoup(html, "html.parser")

    for tag in soup.find_all(["script", "style", "nav"]):
        tag.decompose()

    for iframe in soup.find_all("iframe"):
        src = iframe.get("src", "")
        iframe.replace_with(f"[External tool: {src}]")

    for img in soup.find_all("img"):
        alt = img.get("alt", "image")
        img.replace_with(f"[Image: {alt}]")

    for br in soup.find_all("br"):
        br.replace_with("\n")

    block_tags = {"p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote"}
    for tag in soup.find_all(block_tags):
        tag.insert_before("\n")
        tag.insert_after("\n")

    text = soup.get_text()
    lines = [line.strip() for line in text.splitlines()]
    text = "\n".join(line for line in lines if line)
    return text.strip()


def _split_sentences(text: str) -> list[str]:
    parts = re.split(r"(?<=[.!?])\s+", text)
    return [p for p in parts if p.strip()]


def _token_count(text: str) -> int:
    return len(_encoding.encode(text))


def chunk_text(text: str, meta: ChunkMeta) -> list[TextChunk]:
    if not text.strip():
        return []

    sentences = _split_sentences(text)
    if not sentences:
        return []

    chunks: list[TextChunk] = []
    current_sentences: list[str] = []
    current_tokens = 0

    for sentence in sentences:
        sent_tokens = _token_count(sentence)

        if sent_tokens > CHUNK_SIZE:
            if current_sentences:
                chunk_text_str = " ".join(current_sentences)
                chunks.append(
                    TextChunk(
                        content=chunk_text_str,
                        token_count=_token_count(chunk_text_str),
                        meta=meta,
                    )
                )
                current_sentences = []
                current_tokens = 0

            tokens = _encoding.encode(sentence)
            for i in range(0, len(tokens), CHUNK_SIZE):
                segment = _encoding.decode(tokens[i : i + CHUNK_SIZE])
                chunks.append(
                    TextChunk(
                        content=segment,
                        token_count=min(CHUNK_SIZE, len(tokens) - i),
                        meta=meta,
                    )
                )
            continue

        if current_tokens + sent_tokens > CHUNK_SIZE and current_sentences:
            chunk_text_str = " ".join(current_sentences)
            chunks.append(
                TextChunk(
                    content=chunk_text_str,
                    token_count=_token_count(chunk_text_str),
                    meta=meta,
                )
            )

            overlap_sentences: list[str] = []
            overlap_tokens = 0
            for s in reversed(current_sentences):
                s_tokens = _token_count(s)
                if overlap_tokens + s_tokens > CHUNK_OVERLAP:
                    break
                overlap_sentences.insert(0, s)
                overlap_tokens += s_tokens

            current_sentences = overlap_sentences
            current_tokens = overlap_tokens

        current_sentences.append(sentence)
        current_tokens += sent_tokens

    if current_sentences:
        chunk_text_str = " ".join(current_sentences)
        chunks.append(
            TextChunk(
                content=chunk_text_str,
                token_count=_token_count(chunk_text_str),
                meta=meta,
            )
        )

    return chunks


async def ingest_module(user: User, module: Module, db: AsyncSession) -> list[ContentChunk]:
    from app.config import get_settings

    settings = get_settings()
    access_token = decrypt_token(user.encrypted_access_token, settings)
    all_chunks: list[ContentChunk] = []

    async with CanvasClient(access_token, settings) as client:
        raw_announcements = await client.get_announcements(module.canvas_course_id)
        for ann in raw_announcements:
            content_html = ann.get("message", "")
            content_text = parse_html(content_html)

            posted_str = ann.get("posted_at") or ann.get("created_at", "")
            posted_at = (
                datetime.fromisoformat(posted_str.replace("Z", "+00:00"))
                if posted_str
                else datetime.now(UTC)
            )

            db_ann = Announcement(
                canvas_id=ann["id"],
                module_id=module.id,
                title=ann.get("title", ""),
                content_html=content_html,
                content_text=content_text,
                posted_at=posted_at,
            )
            db.add(db_ann)

            if content_text:
                meta = ChunkMeta(
                    module_id=str(module.id),
                    source_type=SourceType.ANNOUNCEMENT,
                    source_id=str(ann["id"]),
                    source_title=ann.get("title", ""),
                    source_url=ann.get("html_url", ""),
                )
                for tc in chunk_text(content_text, meta):
                    chunk = ContentChunk(
                        module_id=module.id,
                        source_type=SourceType.ANNOUNCEMENT,
                        source_id=str(ann["id"]),
                        source_title=ann.get("title", ""),
                        source_url=ann.get("html_url", ""),
                        content=tc.content,
                        token_count=tc.token_count,
                    )
                    db.add(chunk)
                    all_chunks.append(chunk)

        raw_assignments = await client.get_assignments(module.canvas_course_id)
        for asgn in raw_assignments:
            desc_html = asgn.get("description", "") or ""
            desc_text = parse_html(desc_html)

            due_str = asgn.get("due_at")
            due_at = datetime.fromisoformat(due_str.replace("Z", "+00:00")) if due_str else None

            db_asgn = Assignment(
                canvas_id=asgn["id"],
                module_id=module.id,
                title=asgn.get("name", ""),
                description_html=desc_html,
                description_text=desc_text,
                due_at=due_at,
                points_possible=asgn.get("points_possible"),
            )
            db.add(db_asgn)

            if desc_text:
                meta = ChunkMeta(
                    module_id=str(module.id),
                    source_type=SourceType.ASSIGNMENT,
                    source_id=str(asgn["id"]),
                    source_title=asgn.get("name", ""),
                    source_url=asgn.get("html_url", ""),
                )
                for tc in chunk_text(desc_text, meta):
                    chunk = ContentChunk(
                        module_id=module.id,
                        source_type=SourceType.ASSIGNMENT,
                        source_id=str(asgn["id"]),
                        source_title=asgn.get("name", ""),
                        source_url=asgn.get("html_url", ""),
                        content=tc.content,
                        token_count=tc.token_count,
                    )
                    db.add(chunk)
                    all_chunks.append(chunk)

    await db.flush()

    if all_chunks:
        logger.info("Embedding %d chunks for module %s", len(all_chunks), module.code)
        await embed_chunks(all_chunks, db)

    module.last_synced_at = datetime.now(UTC)
    await db.commit()

    logger.info(
        "Ingested module %s: %d announcements, %d assignments, %d chunks",
        module.code,
        len(raw_announcements),
        len(raw_assignments),
        len(all_chunks),
    )
    return all_chunks


async def sync_user_modules(user: User, db: AsyncSession) -> dict:
    from sqlalchemy import select

    from app.config import get_settings

    settings = get_settings()
    access_token = decrypt_token(user.encrypted_access_token, settings)

    async with CanvasClient(access_token, settings) as client:
        courses = await client.get_user_courses()

    total_chunks = 0
    synced_modules = []

    for course in courses:
        course_id = course["id"]
        course_name = course.get("name", "")
        course_code = course.get("course_code", "")
        term_name = ""
        if course.get("term"):
            term_name = course["term"].get("name", "")

        result = await db.execute(
            select(Module).where(Module.canvas_course_id == course_id, Module.user_id == user.id)
        )
        module = result.scalar_one_or_none()

        if not module:
            module = Module(
                canvas_course_id=course_id,
                user_id=user.id,
                name=course_name,
                code=course_code,
                term=term_name,
            )
            db.add(module)
            await db.flush()

        chunks = await ingest_module(user, module, db)
        total_chunks += len(chunks)
        synced_modules.append(module.code)

    return {
        "modules_synced": len(synced_modules),
        "total_chunks": total_chunks,
        "modules": synced_modules,
    }
