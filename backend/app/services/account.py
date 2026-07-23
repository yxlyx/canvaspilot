import json
import zipfile
from io import BytesIO

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.exceptions import WikiBaseError
from app.models.flashcard import FlashcardAttempt, FlashcardDeck, LearningEvidence
from app.models.m3 import MarkedPaper, ProviderSetting, StudyOutput, WikiRevision
from app.models.settings import UserPreference
from app.models.source import Source
from app.models.user import User
from app.models.wiki import WikiPage
from app.services.exports import ExportFile, canonical_markdown

MAX_ACCOUNT_EXPORT_BYTES = 100 * 1024 * 1024


def _json_bytes(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, indent=2, default=str).encode()


def _safe_component(value: str) -> str:
    cleaned = "".join(character for character in value if character.isalnum() or character in "-_.")
    return cleaned.strip("._") or "file"


def _write(archive: zipfile.ZipFile, name: str, content: bytes, total: list[int]) -> None:
    total[0] += len(content)
    if total[0] > MAX_ACCOUNT_EXPORT_BYTES:
        raise WikiBaseError(413, "export_too_large", "Account archive exceeds 100 MiB")
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o600 << 16
    archive.writestr(info, content)


async def export_account(user: User, db: AsyncSession) -> ExportFile:
    sources = list(
        (
            await db.execute(
                select(Source)
                .options(selectinload(Source.chunks))
                .where(Source.user_id == user.id)
                .order_by(Source.created_at.asc())
            )
        )
        .scalars()
        .unique()
    )
    pages = list(
        (
            await db.execute(
                select(WikiPage)
                .options(selectinload(WikiPage.citations))
                .where(WikiPage.user_id == user.id)
                .order_by(WikiPage.slug.asc())
            )
        )
        .scalars()
        .unique()
    )
    revisions = list(
        (await db.execute(select(WikiRevision).where(WikiRevision.user_id == user.id))).scalars()
    )
    outputs = list(
        (
            await db.execute(
                select(StudyOutput)
                .options(selectinload(StudyOutput.citations))
                .where(StudyOutput.user_id == user.id)
            )
        )
        .scalars()
        .unique()
    )
    decks = list(
        (
            await db.execute(
                select(FlashcardDeck)
                .options(selectinload(FlashcardDeck.cards))
                .where(FlashcardDeck.user_id == user.id)
            )
        )
        .scalars()
        .unique()
    )
    attempts = list(
        (
            await db.execute(select(FlashcardAttempt).where(FlashcardAttempt.user_id == user.id))
        ).scalars()
    )
    evidence = list(
        (
            await db.execute(select(LearningEvidence).where(LearningEvidence.user_id == user.id))
        ).scalars()
    )
    papers = list(
        (
            await db.execute(
                select(MarkedPaper)
                .options(selectinload(MarkedPaper.questions))
                .where(MarkedPaper.user_id == user.id)
            )
        )
        .scalars()
        .unique()
    )
    providers = list(
        (
            await db.execute(select(ProviderSetting).where(ProviderSetting.user_id == user.id))
        ).scalars()
    )
    preferences = await db.get(UserPreference, user.id)

    output = BytesIO()
    total = [0]
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        _write(
            archive,
            "account/profile.json",
            _json_bytes(
                {
                    "id": user.id,
                    "name": user.name,
                    "email": user.email,
                    "created_at": user.created_at,
                    "preferences": (
                        {
                            "theme": preferences.theme,
                            "motion_preference": preferences.motion_preference,
                            "default_module_id": preferences.default_module_id,
                            "daily_review_target": preferences.daily_review_target,
                            "reminders": {
                                "daily_review": preferences.reminder_daily_review,
                                "processing_attention": preferences.reminder_processing_attention,
                                "paper_review": preferences.reminder_paper_review,
                                "health_attention": preferences.reminder_health_attention,
                            },
                        }
                        if preferences
                        else None
                    ),
                }
            ),
            total,
        )
        for source in sources:
            source_dir = f"sources/{source.id}"
            _write(
                archive,
                f"{source_dir}/metadata.json",
                _json_bytes(
                    {
                        "id": source.id,
                        "type": source.source_type.value,
                        "origin": source.origin,
                        "title": source.title,
                        "source_url": source.source_url,
                        "citation_label": source.citation_label,
                        "topic_tags": source.topic_tags,
                        "status": source.status.value,
                        "course_context": source.course_context,
                        "project_context": source.project_context,
                        "import_error": source.import_error,
                        "created_at": source.created_at,
                        "updated_at": source.updated_at,
                    }
                ),
                total,
            )
            readable = "\n\n".join(
                f"## {chunk.location_label or f'Chunk {chunk.chunk_index + 1}'}\n\n{chunk.content}"
                for chunk in source.chunks
            )
            _write(archive, f"{source_dir}/parsed-content.md", readable.encode(), total)
        for page in pages:
            _write(
                archive,
                f"wiki/{_safe_component(page.slug)}.md",
                canonical_markdown(page).encode(),
                total,
            )
        _write(
            archive,
            "wiki/revisions.json",
            _json_bytes(
                [
                    {
                        "id": item.id,
                        "page_id": item.page_id,
                        "revision_number": item.revision_number,
                        "title": item.title,
                        "markdown": item.markdown,
                        "source_ids": item.source_ids,
                        "citation_count": item.citation_count,
                        "change_summary": item.change_summary,
                        "created_at": item.created_at,
                    }
                    for item in revisions
                ]
            ),
            total,
        )
        _write(
            archive,
            "study-guides/guides.json",
            _json_bytes(
                [
                    {
                        "id": item.id,
                        "type": item.output_type,
                        "title": item.title,
                        "status": item.status,
                        "content": item.content,
                        "source_ids": item.source_ids,
                        "wiki_page_id": item.wiki_page_id,
                        "message": item.message,
                        "citations": [
                            {
                                "source_id": citation.source_id,
                                "citation_ref": citation.citation_ref,
                                "source_title": citation.source_title,
                                "snippet": citation.snippet,
                            }
                            for citation in item.citations
                        ],
                        "created_at": item.created_at,
                    }
                    for item in outputs
                ]
            ),
            total,
        )
        _write(
            archive,
            "learning/flashcards.json",
            _json_bytes(
                [
                    {
                        "id": deck.id,
                        "title": deck.title,
                        "description": deck.description,
                        "topic_tags": deck.topic_tags,
                        "cards": [
                            {
                                "id": card.id,
                                "question": card.question,
                                "answer": card.answer,
                                "topic_tag": card.topic_tag,
                                "citation_ref": card.citation_ref,
                                "source_title": card.source_title,
                            }
                            for card in deck.cards
                        ],
                    }
                    for deck in decks
                ]
            ),
            total,
        )
        _write(
            archive,
            "learning/attempts.json",
            _json_bytes(
                [
                    {
                        "id": item.id,
                        "deck_id": item.deck_id,
                        "card_id": item.card_id,
                        "is_correct": item.is_correct,
                        "confidence": item.confidence,
                        "created_at": item.created_at,
                    }
                    for item in attempts
                ]
            ),
            total,
        )
        _write(
            archive,
            "learning/evidence.json",
            _json_bytes(
                [
                    {
                        "id": item.id,
                        "evidence_type": item.evidence_type,
                        "topic_tag": item.topic_tag,
                        "is_correct": item.is_correct,
                        "confidence": item.confidence,
                        "citation_ref": item.citation_ref,
                        "occurred_at": item.occurred_at,
                    }
                    for item in evidence
                ]
            ),
            total,
        )
        for paper in papers:
            base = f"marked-papers/{paper.id}"
            _write(
                archive,
                f"{base}/{_safe_component(paper.filename)}",
                paper.raw_content,
                total,
            )
            _write(
                archive,
                f"{base}/questions.json",
                _json_bytes(
                    [
                        {
                            "id": question.id,
                            "question_number": question.question_number,
                            "question_text": question.question_text,
                            "awarded_marks": question.awarded_marks,
                            "available_marks": question.available_marks,
                            "feedback": question.feedback,
                            "topic_tag": question.topic_tag,
                            "confidence": question.confidence,
                            "reviewed": question.reviewed,
                            "reviewed_at": question.reviewed_at,
                        }
                        for question in paper.questions
                    ]
                ),
                total,
            )
        _write(
            archive,
            "account/providers.json",
            _json_bytes(
                [
                    {
                        "provider": item.provider,
                        "model": item.model,
                        "endpoint": item.endpoint,
                        "status": item.status,
                        "last_tested_at": item.last_tested_at,
                    }
                    for item in providers
                ]
            ),
            total,
        )
    content = output.getvalue()
    if len(content) > MAX_ACCOUNT_EXPORT_BYTES:
        raise WikiBaseError(413, "export_too_large", "Account archive exceeds 100 MiB")
    return ExportFile(content, "wikibase-account.zip", "application/zip")
