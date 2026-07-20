import base64
import binascii
import re
import uuid
from datetime import UTC, datetime

from sqlalchemy import delete, func, select, text, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.exceptions import NotFoundError, WikiBaseError
from app.models.flashcard import LearningEvidence
from app.models.m3 import MarkedPaper, MarkedPaperQuestion
from app.models.user import User
from app.schemas.m3 import (
    MarkedPaperQuestionCreate,
    MarkedPaperQuestionUpdate,
    MarkedPaperUploadRequest,
)
from app.schemas.sources import normalize_topic_tags
from app.services.pagination import decode_cursor, encode_cursor

MAX_MARKED_PAPER_BYTES = 10 * 1024 * 1024
MAX_MARKED_PAPERS_PER_USER = 100
MAX_MARKED_PAPER_STORAGE_BYTES = 100 * 1024 * 1024
MAX_PAPERS_RETURNED = 100
MAX_QUESTIONS = 200
_QUESTION_RE = re.compile(r"^Q(\d+)\s*:\s*(.+)$", re.IGNORECASE)
_MARKS_RE = re.compile(
    r"^Marks\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*([0-9]+(?:\.[0-9]+)?)$",
    re.IGNORECASE,
)


def _text_blocks(text: str):
    """Yield blocks without allocating a list proportional to the input structure."""
    normalized = text.replace("\r\n", "\n")
    start = 0
    for separator in re.finditer(r"\n\s*\n", normalized):
        yield normalized[start : separator.start()]
        start = separator.end()
    yield normalized[start:]


def extract_supported_text(text: str) -> tuple[list[dict], str]:
    """Parse explicit text fields only; handwriting/images are never inferred or OCR'd."""
    questions: list[dict] = []
    for block in _text_blocks(text):
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if not lines:
            continue
        question_match = _QUESTION_RE.match(lines[0])
        if not question_match:
            continue
        values = {
            "question_number": int(question_match.group(1)),
            "question_text": question_match.group(2)[:20_000],
            "awarded_marks": None,
            "available_marks": None,
            "feedback": "",
            "topic_tag": "general",
            "confidence": 0.5,
        }
        for line in lines[1:]:
            marks = _MARKS_RE.match(line)
            if marks:
                values["awarded_marks"] = float(marks.group(1))
                values["available_marks"] = float(marks.group(2))
            elif line.lower().startswith("topic:"):
                topics = normalize_topic_tags([line.split(":", 1)[1]])
                values["topic_tag"] = topics[0][:100] if topics else "general"
            elif line.lower().startswith("feedback:"):
                values["feedback"] = line.split(":", 1)[1].strip()[:10_000]
            elif line.lower().startswith("confidence:"):
                try:
                    values["confidence"] = min(1.0, max(0.0, float(line.split(":", 1)[1])))
                except ValueError:
                    values["confidence"] = 0.0
        if values["available_marks"] is not None and values["awarded_marks"] is not None:
            if (
                values["available_marks"] <= 0
                or values["awarded_marks"] > values["available_marks"]
            ):
                raise WikiBaseError(
                    422, "invalid_marks", "awarded_marks cannot exceed available_marks"
                )
        questions.append(values)
        if len(questions) == MAX_QUESTIONS:
            break
    if questions:
        return questions, "Extracted explicit text fields; review is required before meter use."
    return (
        [],
        "No supported structured text was found; no OCR or inferred evidence was created.",
    )


async def upload_marked_paper(
    user: User, payload: MarkedPaperUploadRequest, db: AsyncSession
) -> MarkedPaper:
    try:
        raw = base64.b64decode(payload.content_base64, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise WikiBaseError(422, "invalid_file", "content_base64 must be valid base64") from exc
    if len(raw) > MAX_MARKED_PAPER_BYTES:
        raise WikiBaseError(413, "file_too_large", "Marked papers are limited to 10 MiB")
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"marked-paper-quota:{user.id}"},
    )
    paper_count, stored_bytes = (
        await db.execute(
            select(
                func.count(MarkedPaper.id),
                func.coalesce(func.sum(func.octet_length(MarkedPaper.raw_content)), 0),
            ).where(MarkedPaper.user_id == user.id)
        )
    ).one()
    if paper_count >= MAX_MARKED_PAPERS_PER_USER:
        raise WikiBaseError(413, "paper_quota_exceeded", "Marked paper count quota exceeded")
    if stored_bytes + len(raw) > MAX_MARKED_PAPER_STORAGE_BYTES:
        raise WikiBaseError(413, "paper_quota_exceeded", "Marked paper storage quota exceeded")

    questions: list[dict] = []
    if payload.content_type in {"text/plain", "text/markdown"}:
        try:
            decoded_text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise WikiBaseError(422, "invalid_file", "Text marked papers must be UTF-8") from exc
        questions, message = extract_supported_text(decoded_text)
        numbers = [question["question_number"] for question in questions]
        if len(numbers) != len(set(numbers)):
            raise WikiBaseError(422, "duplicate_question_number", "Question numbers must be unique")
        status = "pending_review" if questions else "unsupported"
    else:
        status = "unsupported"
        message = "PDF text extraction/OCR is not enabled; no evidence was fabricated."

    paper = MarkedPaper(
        user_id=user.id,
        filename=payload.filename,
        content_type=payload.content_type,
        raw_content=raw,
        extraction_status=status,
        extraction_message=message,
    )
    db.add(paper)
    await db.flush()
    for values in questions:
        db.add(MarkedPaperQuestion(paper_id=paper.id, reviewed=False, **values))
    await db.flush()
    await db.refresh(paper, attribute_names=["questions"])
    return paper


async def list_marked_papers(
    user: User, db: AsyncSession, limit: int = 100, offset: int = 0
) -> list[MarkedPaper]:
    result = await db.execute(
        select(MarkedPaper)
        .options(selectinload(MarkedPaper.questions))
        .where(MarkedPaper.user_id == user.id)
        .order_by(MarkedPaper.created_at.desc(), MarkedPaper.id.desc())
        .offset(offset)
        .limit(min(limit, MAX_PAPERS_RETURNED))
    )
    return list(result.scalars().unique())


async def page_marked_papers(
    user: User, db: AsyncSession, limit: int = 20, cursor: str | None = None
) -> tuple[list[MarkedPaper], str | None]:
    statement = (
        select(MarkedPaper)
        .options(selectinload(MarkedPaper.questions))
        .where(MarkedPaper.user_id == user.id)
        .order_by(MarkedPaper.created_at.desc(), MarkedPaper.id.desc())
    )
    if cursor is not None:
        statement = statement.where(
            tuple_(MarkedPaper.created_at, MarkedPaper.id) < decode_cursor(cursor)
        )
    rows = list((await db.execute(statement.limit(limit + 1))).scalars().unique().all())
    items = rows[:limit]
    next_cursor = (
        encode_cursor(items[-1].created_at, items[-1].id) if len(rows) > limit and items else None
    )
    return items, next_cursor


async def get_marked_paper(user: User, paper_id: uuid.UUID, db: AsyncSession) -> MarkedPaper:
    result = await db.execute(
        select(MarkedPaper)
        .options(selectinload(MarkedPaper.questions))
        .where(MarkedPaper.user_id == user.id, MarkedPaper.id == paper_id)
    )
    paper = result.scalar_one_or_none()
    if paper is None:
        raise NotFoundError("Marked paper not found")
    return paper


async def create_question(
    user: User,
    paper_id: uuid.UUID,
    payload: MarkedPaperQuestionCreate,
    db: AsyncSession,
) -> MarkedPaper:
    paper = await get_marked_paper(user, paper_id, db)
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"marked-paper-questions:{paper_id}"},
    )
    question_count = await db.scalar(
        select(func.count(MarkedPaperQuestion.id)).where(MarkedPaperQuestion.paper_id == paper_id)
    )
    if question_count >= MAX_QUESTIONS:
        raise WikiBaseError(
            413, "question_quota_exceeded", "Marked papers are limited to 200 questions"
        )
    duplicate = await db.scalar(
        select(MarkedPaperQuestion.id).where(
            MarkedPaperQuestion.paper_id == paper_id,
            MarkedPaperQuestion.question_number == payload.question_number,
        )
    )
    if duplicate is not None:
        raise WikiBaseError(422, "duplicate_question_number", "Question numbers must be unique")
    if (
        payload.awarded_marks is not None
        and payload.available_marks is not None
        and payload.awarded_marks > payload.available_marks
    ):
        raise WikiBaseError(422, "invalid_marks", "awarded_marks cannot exceed available_marks")
    if payload.reviewed and (payload.awarded_marks is None or payload.available_marks is None):
        raise WikiBaseError(422, "incomplete_evidence", "Reviewed evidence requires both marks")
    question = MarkedPaperQuestion(
        paper_id=paper_id,
        reviewed_at=datetime.now(UTC) if payload.reviewed else None,
        **payload.model_dump(),
    )
    db.add(question)
    await db.flush()
    if question.reviewed:
        db.add(
            LearningEvidence(
                user_id=user.id,
                evidence_type="marked_paper",
                topic_tag=question.topic_tag,
                marked_paper_question_id=question.id,
                is_correct=question.awarded_marks / question.available_marks >= 0.6,
                confidence=round(question.confidence * 5),
                citation_ref=f"Private marked paper question {question.question_number}",
            )
        )
    unreviewed = await db.scalar(
        select(func.count(MarkedPaperQuestion.id)).where(
            MarkedPaperQuestion.paper_id == paper_id,
            MarkedPaperQuestion.reviewed.is_(False),
        )
    )
    paper.extraction_status = "pending_review" if unreviewed else "reviewed"
    paper.extraction_message = "Manually entered question; review state is user supplied."
    await db.flush()
    return await get_marked_paper(user, paper_id, db)


async def update_question(
    user: User,
    paper_id: uuid.UUID,
    question_id: uuid.UUID,
    payload: MarkedPaperQuestionUpdate,
    db: AsyncSession,
) -> MarkedPaper:
    result = await db.execute(
        select(MarkedPaperQuestion)
        .join(MarkedPaper, MarkedPaperQuestion.paper_id == MarkedPaper.id)
        .where(
            MarkedPaper.user_id == user.id,
            MarkedPaper.id == paper_id,
            MarkedPaperQuestion.id == question_id,
        )
        .with_for_update(of=MarkedPaperQuestion)
    )
    question = result.scalar_one_or_none()
    if question is None:
        raise NotFoundError("Marked paper question not found")
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(question, field, value)
    if question.awarded_marks is not None and question.available_marks is not None:
        if question.awarded_marks > question.available_marks:
            raise WikiBaseError(422, "invalid_marks", "awarded_marks cannot exceed available_marks")
    question.reviewed_at = datetime.now(UTC) if question.reviewed else None
    await db.execute(
        delete(LearningEvidence).where(LearningEvidence.marked_paper_question_id == question.id)
    )
    if question.reviewed:
        if question.awarded_marks is None or question.available_marks is None:
            raise WikiBaseError(422, "incomplete_evidence", "Reviewed evidence requires both marks")
        db.add(
            LearningEvidence(
                user_id=user.id,
                evidence_type="marked_paper",
                topic_tag=question.topic_tag,
                marked_paper_question_id=question.id,
                is_correct=question.awarded_marks / question.available_marks >= 0.6,
                confidence=round(question.confidence * 5),
                citation_ref=f"Private marked paper question {question.question_number}",
            )
        )
    await db.flush()
    remaining = await db.scalar(
        select(func.count(MarkedPaperQuestion.id)).where(
            MarkedPaperQuestion.paper_id == paper_id,
            MarkedPaperQuestion.reviewed.is_(False),
        )
    )
    paper = await db.get(MarkedPaper, paper_id)
    if paper is not None:
        paper.extraction_status = "reviewed" if remaining == 0 else "pending_review"
    await db.flush()
    return await get_marked_paper(user, paper_id, db)


async def delete_question(
    user: User, paper_id: uuid.UUID, question_id: uuid.UUID, db: AsyncSession
) -> MarkedPaper:
    result = await db.execute(
        select(MarkedPaperQuestion)
        .join(MarkedPaper, MarkedPaperQuestion.paper_id == MarkedPaper.id)
        .where(
            MarkedPaper.user_id == user.id,
            MarkedPaper.id == paper_id,
            MarkedPaperQuestion.id == question_id,
        )
    )
    question = result.scalar_one_or_none()
    if question is None:
        raise NotFoundError("Marked paper question not found")
    await db.delete(question)
    await db.flush()
    remaining, unreviewed = (
        await db.execute(
            select(
                func.count(MarkedPaperQuestion.id),
                func.count(MarkedPaperQuestion.id).filter(MarkedPaperQuestion.reviewed.is_(False)),
            ).where(MarkedPaperQuestion.paper_id == paper_id)
        )
    ).one()
    paper = await db.get(MarkedPaper, paper_id)
    if paper is not None:
        paper.extraction_status = (
            "unsupported" if not remaining else "pending_review" if unreviewed else "reviewed"
        )
    await db.flush()
    return await get_marked_paper(user, paper_id, db)


async def delete_marked_paper(user: User, paper_id: uuid.UUID, db: AsyncSession) -> None:
    paper = await get_marked_paper(user, paper_id, db)
    await db.delete(paper)
    await db.flush()
