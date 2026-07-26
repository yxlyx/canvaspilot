import re
import uuid
from dataclasses import dataclass

from sqlalchemy import select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.exceptions import NotFoundError
from app.models.m3 import StudyOutput, StudyOutputCitation
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk, active_source_chunk_predicate
from app.models.user import User
from app.models.wiki import WikiPage
from app.schemas.m3 import StudyOutputGenerateRequest
from app.services.pagination import decode_cursor, encode_cursor

MIN_EVIDENCE_CHARS = 40
MAX_EVIDENCE_ITEMS = 12
MAX_EVIDENCE_PER_SOURCE = 3


@dataclass
class Evidence:
    text: str
    source_id: uuid.UUID
    source_chunk_id: uuid.UUID | None
    source_title: str
    citation_ref: str


def _sentence(text: str, limit: int = 400) -> str:
    compact = " ".join(text.split())
    match = re.search(r"(?<=[.!?])\s", compact)
    if match and match.start() <= limit:
        return compact[: match.start()]
    return compact[:limit].rstrip()


def build_grounded_markdown(output_type: str, evidence: list[Evidence]) -> str:
    """Build extractive output: every statement is copied from, and cites, evidence."""
    lines: list[str] = []
    for index, item in enumerate(evidence[:MAX_EVIDENCE_ITEMS], 1):
        sentence = _sentence(item.text)
        if not sentence:
            continue
        if output_type == "outline":
            lines.append(f"- {sentence} [{index}]")
        elif output_type == "study_guide":
            lines.extend(
                [
                    f"## Review point {index}",
                    f"{sentence} [{index}]",
                    f"- [ ] Explain review point {index} from the cited evidence.",
                ]
            )
        else:
            lines.append(f"{sentence} [{index}]")
    return "\n\n".join(lines)


async def _evidence_for_request(
    user: User, payload: StudyOutputGenerateRequest, db: AsyncSession
) -> tuple[list[Evidence], list[uuid.UUID], uuid.UUID | None, bool]:
    if payload.wiki_page_id is not None:
        result = await db.execute(
            select(WikiPage)
            .options(selectinload(WikiPage.citations))
            .where(
                WikiPage.id == payload.wiki_page_id,
                WikiPage.user_id == user.id,
                WikiPage.is_current.is_(True),
            )
        )
        page = result.scalar_one_or_none()
        if page is None:
            raise NotFoundError("Wiki page not found")
        citations = [
            citation
            for citation in sorted(page.citations, key=lambda item: item.citation_key)
            if citation.source_chunk_id is not None
        ]
        selected = citations[:MAX_EVIDENCE_ITEMS]
        chunks = {
            chunk.id: (chunk, source)
            for chunk, source in (
                await db.execute(
                    select(SourceChunk, Source)
                    .join(Source, SourceChunk.source_id == Source.id)
                    .where(
                        Source.user_id == user.id,
                        SourceChunk.id.in_([citation.source_chunk_id for citation in selected]),
                        active_source_chunk_predicate(SourceChunk, Source),
                    )
                )
            ).all()
        }
        evidence = [
            Evidence(
                text=chunks[citation.source_chunk_id][0].content,
                source_id=citation.source_id,
                source_chunk_id=citation.source_chunk_id,
                source_title=citation.source_title,
                citation_ref=citation.citation_ref,
            )
            for citation in selected
            if citation.source_chunk_id in chunks
            and chunks[citation.source_chunk_id][1].id == citation.source_id
        ]
        return evidence, page.source_ids, page.id, len(citations) > MAX_EVIDENCE_ITEMS

    if payload.source_chunk_ids is not None:
        rows = (
            await db.execute(
                select(SourceChunk, Source)
                .join(Source, SourceChunk.source_id == Source.id)
                .where(
                    Source.user_id == user.id,
                    Source.status == SourceStatus.READY,
                    SourceChunk.id.in_(payload.source_chunk_ids),
                    active_source_chunk_predicate(SourceChunk, Source),
                )
                .order_by(Source.title.asc(), SourceChunk.chunk_index.asc(), SourceChunk.id.asc())
            )
        ).all()
        if {chunk.id for chunk, _ in rows} != set(payload.source_chunk_ids):
            raise NotFoundError("One or more ready source chunks were not found")
        truncated = False
    else:
        source_statement = (
            select(Source)
            .where(
                Source.user_id == user.id,
                Source.status == SourceStatus.READY,
                Source.chunks.any(active_source_chunk_predicate(SourceChunk, Source)),
            )
            .order_by(Source.title.asc(), Source.id.asc())
        )
        if payload.source_ids is not None:
            source_statement = source_statement.where(Source.id.in_(payload.source_ids))
        else:
            source_statement = source_statement.where(
                Source.topic_tags.contains([payload.topic.lower()])
            )
        sources = list((await db.execute(source_statement.limit(MAX_EVIDENCE_ITEMS + 1))).scalars())
        if payload.source_ids is not None and {source.id for source in sources} != set(
            payload.source_ids
        ):
            raise NotFoundError("One or more ready sources were not found")
        truncated = len(sources) > MAX_EVIDENCE_ITEMS
        rows = []
        for source in sources[:MAX_EVIDENCE_ITEMS]:
            source_rows = (
                await db.execute(
                    select(SourceChunk, Source)
                    .join(Source, SourceChunk.source_id == Source.id)
                    .where(
                        SourceChunk.source_id == source.id,
                        active_source_chunk_predicate(SourceChunk, Source),
                    )
                    .order_by(SourceChunk.chunk_index.asc(), SourceChunk.id.asc())
                    .limit(MAX_EVIDENCE_PER_SOURCE + 1)
                )
            ).all()
            truncated = truncated or len(source_rows) > MAX_EVIDENCE_PER_SOURCE
            rows.extend(source_rows[:MAX_EVIDENCE_PER_SOURCE])
        if len(rows) > MAX_EVIDENCE_ITEMS:
            rows = rows[:MAX_EVIDENCE_ITEMS]
            truncated = True

    evidence = [
        Evidence(
            text=chunk.content,
            source_id=source.id,
            source_chunk_id=chunk.id,
            source_title=source.title,
            citation_ref=chunk.citation_ref,
        )
        for chunk, source in rows
    ]
    return (
        evidence,
        list(dict.fromkeys(item.source_id for item in evidence)),
        None,
        truncated,
    )


async def generate_study_output(
    user: User, payload: StudyOutputGenerateRequest, db: AsyncSession
) -> StudyOutput:
    evidence, source_ids, wiki_page_id, truncated = await _evidence_for_request(user, payload, db)
    usable = [item for item in evidence if len(" ".join(item.text.split())) >= MIN_EVIDENCE_CHARS]
    grounded = bool(usable)
    content = build_grounded_markdown(payload.output_type, usable) if grounded else ""
    if grounded and truncated:
        content += (
            "\n\n> Evidence was deterministically truncated to configured per-source "
            "and output limits."
        )
    output = StudyOutput(
        user_id=user.id,
        output_type=payload.output_type,
        title=payload.title or payload.output_type.replace("_", " ").title(),
        status="grounded" if grounded else "insufficient_evidence",
        content=content,
        source_ids=source_ids,
        wiki_page_id=wiki_page_id,
        message=(
            (
                "Generated only from cited workspace evidence; evidence was truncated "
                "deterministically."
                if truncated
                else "Generated only from cited workspace evidence."
            )
            if grounded
            else "Insufficient cited workspace evidence to generate this output."
        ),
    )
    db.add(output)
    await db.flush()
    for index, item in enumerate(usable[:MAX_EVIDENCE_ITEMS], 1):
        db.add(
            StudyOutputCitation(
                output_id=output.id,
                source_id=item.source_id,
                source_chunk_id=item.source_chunk_id,
                citation_key=str(index),
                citation_ref=item.citation_ref,
                source_title=item.source_title,
                snippet=_sentence(item.text, 240),
            )
        )
    await db.flush()
    await db.refresh(output, attribute_names=["citations"])
    return output


async def list_study_outputs(
    user: User, db: AsyncSession, limit: int = 20, offset: int = 0
) -> list[StudyOutput]:
    result = await db.execute(
        select(StudyOutput)
        .options(selectinload(StudyOutput.citations))
        .where(StudyOutput.user_id == user.id)
        .order_by(StudyOutput.created_at.desc(), StudyOutput.id.desc())
        .offset(offset)
        .limit(limit)
    )
    return list(result.scalars().unique().all())


async def page_study_outputs(
    user: User,
    db: AsyncSession,
    limit: int = 20,
    cursor: str | None = None,
    output_type: str | None = None,
) -> tuple[list[StudyOutput], str | None]:
    statement = (
        select(StudyOutput)
        .options(selectinload(StudyOutput.citations))
        .where(StudyOutput.user_id == user.id)
        .order_by(StudyOutput.created_at.desc(), StudyOutput.id.desc())
    )
    if output_type is not None:
        statement = statement.where(StudyOutput.output_type == output_type)
    if cursor is not None:
        statement = statement.where(
            tuple_(StudyOutput.created_at, StudyOutput.id) < decode_cursor(cursor)
        )
    rows = list((await db.execute(statement.limit(limit + 1))).scalars().unique().all())
    items = rows[:limit]
    next_cursor = (
        encode_cursor(items[-1].created_at, items[-1].id) if len(rows) > limit and items else None
    )
    return items, next_cursor


async def get_study_output(user: User, output_id: uuid.UUID, db: AsyncSession) -> StudyOutput:
    result = await db.execute(
        select(StudyOutput)
        .options(selectinload(StudyOutput.citations))
        .where(StudyOutput.id == output_id, StudyOutput.user_id == user.id)
    )
    output = result.scalar_one_or_none()
    if output is None:
        raise NotFoundError("Study output not found")
    return output
