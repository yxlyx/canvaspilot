import json
import zipfile
from io import BytesIO

from sqlalchemy import LargeBinary, Text, cast, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import load_only, raiseload, selectinload

from app.exceptions import WikiBaseError
from app.models.flashcard import (
    Flashcard,
    FlashcardAttempt,
    FlashcardDeck,
    LearningEvidence,
)
from app.models.m3 import (
    MarkedPaper,
    MarkedPaperQuestion,
    ProviderSetting,
    StudyOutput,
    StudyOutputCitation,
    WikiRevision,
)
from app.models.settings import UserPreference
from app.models.source import Source
from app.models.source_chunk import (
    SourceChunk,
    active_source_chunk_predicate,
    is_active_source_chunk,
)
from app.models.user import User
from app.models.wiki import WikiPage
from app.services.exports import ExportFile, canonical_markdown

MAX_ACCOUNT_EXPORT_BYTES = 100 * 1024 * 1024
MAX_ACCOUNT_EXPORT_MEMORY_BYTES = 700 * 1024 * 1024
ACCOUNT_EXPORT_ROW_OVERHEAD_BYTES = 1024
ACCOUNT_EXPORT_VALUE_MEMORY_FACTOR = 6


def _projected_column_bytes(column):
    if isinstance(column.type, LargeBinary):
        size = func.octet_length(column)
    else:
        size = func.octet_length(cast(column, Text))
    return func.coalesce(size, 0)


def _projected_table_bytes(columns, from_clause, *criteria):
    value_bytes = sum((_projected_column_bytes(column) for column in columns), start=0)
    row_bytes = value_bytes * ACCOUNT_EXPORT_VALUE_MEMORY_FACTOR + ACCOUNT_EXPORT_ROW_OVERHEAD_BYTES
    return (
        select(func.coalesce(func.sum(row_bytes), 0))
        .select_from(from_clause)
        .where(*criteria)
        .scalar_subquery()
    )


def _account_export_preflight_statement(user_id):
    sources = Source.__table__
    chunks = SourceChunk.__table__
    pages = WikiPage.__table__
    revisions = WikiRevision.__table__
    outputs = StudyOutput.__table__
    output_citations = StudyOutputCitation.__table__
    decks = FlashcardDeck.__table__
    cards = Flashcard.__table__
    attempts = FlashcardAttempt.__table__
    evidence = LearningEvidence.__table__
    papers = MarkedPaper.__table__
    questions = MarkedPaperQuestion.__table__
    providers = ProviderSetting.__table__
    preferences = UserPreference.__table__
    users = User.__table__

    estimates = [
        _projected_table_bytes(
            [users.c.id, users.c.name, users.c.email, users.c.created_at],
            users,
            users.c.id == user_id,
        ),
        _projected_table_bytes(
            [
                preferences.c.theme,
                preferences.c.motion_preference,
                preferences.c.default_module_id,
                preferences.c.default_enrollment_id,
                preferences.c.daily_review_target,
                preferences.c.reminder_daily_review,
                preferences.c.reminder_processing_attention,
                preferences.c.reminder_paper_review,
                preferences.c.reminder_health_attention,
            ],
            preferences,
            preferences.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                sources.c.id,
                sources.c.source_type,
                sources.c.origin,
                sources.c.title,
                sources.c.source_url,
                sources.c.citation_label,
                sources.c.topic_tags,
                sources.c.status,
                sources.c.course_context,
                sources.c.project_context,
                sources.c.import_error,
                sources.c.created_at,
                sources.c.updated_at,
            ],
            sources,
            sources.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [chunks.c.location_label, chunks.c.chunk_index, chunks.c.content],
            chunks.join(sources, chunks.c.source_id == sources.c.id),
            sources.c.user_id == user_id,
            active_source_chunk_predicate(chunks, sources),
        ),
        _projected_table_bytes(
            [
                pages.c.id,
                pages.c.slug,
                pages.c.title,
                pages.c.updated_at,
                pages.c.source_ids,
                pages.c.citation_count,
                pages.c.backlinks,
                pages.c.markdown,
            ],
            pages,
            pages.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                revisions.c.id,
                revisions.c.page_id,
                revisions.c.revision_number,
                revisions.c.title,
                revisions.c.markdown,
                revisions.c.source_ids,
                revisions.c.citation_count,
                revisions.c.change_summary,
                revisions.c.created_at,
            ],
            revisions,
            revisions.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                outputs.c.id,
                outputs.c.output_type,
                outputs.c.title,
                outputs.c.status,
                outputs.c.content,
                outputs.c.source_ids,
                outputs.c.wiki_page_id,
                outputs.c.message,
                outputs.c.created_at,
            ],
            outputs,
            outputs.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                output_citations.c.source_id,
                output_citations.c.citation_ref,
                output_citations.c.source_title,
                output_citations.c.snippet,
            ],
            output_citations.join(outputs, output_citations.c.output_id == outputs.c.id),
            outputs.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [decks.c.id, decks.c.title, decks.c.description, decks.c.topic_tags],
            decks,
            decks.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                cards.c.id,
                cards.c.question,
                cards.c.answer,
                cards.c.topic_tag,
                cards.c.citation_ref,
                cards.c.source_title,
            ],
            cards.join(decks, cards.c.deck_id == decks.c.id),
            decks.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                attempts.c.id,
                attempts.c.deck_id,
                attempts.c.card_id,
                attempts.c.is_correct,
                attempts.c.confidence,
                attempts.c.created_at,
            ],
            attempts,
            attempts.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                evidence.c.id,
                evidence.c.evidence_type,
                evidence.c.topic_tag,
                evidence.c.is_correct,
                evidence.c.confidence,
                evidence.c.citation_ref,
                evidence.c.occurred_at,
            ],
            evidence,
            evidence.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [papers.c.id, papers.c.filename, papers.c.raw_content],
            papers,
            papers.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                questions.c.id,
                questions.c.question_number,
                questions.c.question_text,
                questions.c.awarded_marks,
                questions.c.available_marks,
                questions.c.feedback,
                questions.c.topic_tag,
                questions.c.confidence,
                questions.c.reviewed,
                questions.c.reviewed_at,
            ],
            questions.join(papers, questions.c.paper_id == papers.c.id),
            papers.c.user_id == user_id,
        ),
        _projected_table_bytes(
            [
                providers.c.provider,
                providers.c.model,
                providers.c.endpoint,
                providers.c.status,
                providers.c.last_tested_at,
            ],
            providers,
            providers.c.user_id == user_id,
        ),
    ]
    return select(sum(estimates, start=0))


async def _preflight_account_export(user_id, db: AsyncSession) -> None:
    estimated_bytes = await db.scalar(_account_export_preflight_statement(user_id))
    if estimated_bytes > MAX_ACCOUNT_EXPORT_MEMORY_BYTES:
        raise WikiBaseError(
            413, "export_too_large", "Account archive is too large to prepare safely"
        )


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
    await _preflight_account_export(user.id, db)

    sources = list(
        (
            await db.execute(
                select(Source)
                .options(
                    load_only(
                        Source.id,
                        Source.source_type,
                        Source.origin,
                        Source.title,
                        Source.source_url,
                        Source.citation_label,
                        Source.topic_tags,
                        Source.status,
                        Source.course_context,
                        Source.project_context,
                        Source.import_error,
                        Source.current_version_id,
                        Source.created_at,
                        Source.updated_at,
                        raiseload=True,
                    ),
                    selectinload(
                        Source.chunks.and_(
                            SourceChunk.source.has(
                                active_source_chunk_predicate(SourceChunk, Source)
                            )
                        )
                    )
                    .load_only(
                        SourceChunk.chunk_index,
                        SourceChunk.source_version_id,
                        SourceChunk.location_label,
                        SourceChunk.content,
                        raiseload=True,
                    )
                    .raiseload("*"),
                    raiseload("*"),
                )
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
                .options(
                    load_only(
                        WikiPage.id,
                        WikiPage.slug,
                        WikiPage.title,
                        WikiPage.updated_at,
                        WikiPage.source_ids,
                        WikiPage.citation_count,
                        WikiPage.backlinks,
                        WikiPage.markdown,
                        raiseload=True,
                    ),
                    raiseload("*"),
                )
                .where(WikiPage.user_id == user.id)
                .order_by(WikiPage.slug.asc())
            )
        )
        .scalars()
        .unique()
    )
    revisions = list(
        (
            await db.execute(
                select(WikiRevision)
                .options(
                    load_only(
                        WikiRevision.id,
                        WikiRevision.page_id,
                        WikiRevision.revision_number,
                        WikiRevision.title,
                        WikiRevision.markdown,
                        WikiRevision.source_ids,
                        WikiRevision.citation_count,
                        WikiRevision.change_summary,
                        WikiRevision.created_at,
                        raiseload=True,
                    ),
                    raiseload("*"),
                )
                .where(WikiRevision.user_id == user.id)
            )
        ).scalars()
    )
    outputs = list(
        (
            await db.execute(
                select(StudyOutput)
                .options(
                    load_only(
                        StudyOutput.id,
                        StudyOutput.output_type,
                        StudyOutput.title,
                        StudyOutput.status,
                        StudyOutput.content,
                        StudyOutput.source_ids,
                        StudyOutput.wiki_page_id,
                        StudyOutput.message,
                        StudyOutput.created_at,
                        raiseload=True,
                    ),
                    selectinload(StudyOutput.citations)
                    .load_only(
                        StudyOutputCitation.source_id,
                        StudyOutputCitation.citation_ref,
                        StudyOutputCitation.source_title,
                        StudyOutputCitation.snippet,
                        raiseload=True,
                    )
                    .raiseload("*"),
                    raiseload("*"),
                )
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
                .options(
                    load_only(
                        FlashcardDeck.id,
                        FlashcardDeck.title,
                        FlashcardDeck.description,
                        FlashcardDeck.topic_tags,
                        raiseload=True,
                    ),
                    selectinload(FlashcardDeck.cards)
                    .load_only(
                        Flashcard.id,
                        Flashcard.question,
                        Flashcard.answer,
                        Flashcard.topic_tag,
                        Flashcard.citation_ref,
                        Flashcard.source_title,
                        raiseload=True,
                    )
                    .raiseload("*"),
                    raiseload("*"),
                )
                .where(FlashcardDeck.user_id == user.id)
            )
        )
        .scalars()
        .unique()
    )
    attempts = list(
        (
            await db.execute(
                select(FlashcardAttempt)
                .options(
                    load_only(
                        FlashcardAttempt.id,
                        FlashcardAttempt.deck_id,
                        FlashcardAttempt.card_id,
                        FlashcardAttempt.is_correct,
                        FlashcardAttempt.confidence,
                        FlashcardAttempt.created_at,
                        raiseload=True,
                    ),
                    raiseload("*"),
                )
                .where(FlashcardAttempt.user_id == user.id)
            )
        ).scalars()
    )
    evidence = list(
        (
            await db.execute(
                select(LearningEvidence)
                .options(
                    load_only(
                        LearningEvidence.id,
                        LearningEvidence.evidence_type,
                        LearningEvidence.topic_tag,
                        LearningEvidence.is_correct,
                        LearningEvidence.confidence,
                        LearningEvidence.citation_ref,
                        LearningEvidence.occurred_at,
                        raiseload=True,
                    ),
                    raiseload("*"),
                )
                .where(LearningEvidence.user_id == user.id)
            )
        ).scalars()
    )
    papers = list(
        (
            await db.execute(
                select(MarkedPaper)
                .options(
                    load_only(
                        MarkedPaper.id,
                        MarkedPaper.filename,
                        MarkedPaper.raw_content,
                        raiseload=True,
                    ),
                    selectinload(MarkedPaper.questions)
                    .load_only(
                        MarkedPaperQuestion.id,
                        MarkedPaperQuestion.question_number,
                        MarkedPaperQuestion.question_text,
                        MarkedPaperQuestion.awarded_marks,
                        MarkedPaperQuestion.available_marks,
                        MarkedPaperQuestion.feedback,
                        MarkedPaperQuestion.topic_tag,
                        MarkedPaperQuestion.confidence,
                        MarkedPaperQuestion.reviewed,
                        MarkedPaperQuestion.reviewed_at,
                        raiseload=True,
                    )
                    .raiseload("*"),
                    raiseload("*"),
                )
                .where(MarkedPaper.user_id == user.id)
            )
        )
        .scalars()
        .unique()
    )
    providers = list(
        (
            await db.execute(
                select(ProviderSetting)
                .options(
                    load_only(
                        ProviderSetting.provider,
                        ProviderSetting.model,
                        ProviderSetting.endpoint,
                        ProviderSetting.auth_method,
                        ProviderSetting.provider_account_label,
                        ProviderSetting.status,
                        ProviderSetting.last_tested_at,
                        raiseload=True,
                    ),
                    raiseload("*"),
                )
                .where(ProviderSetting.user_id == user.id)
            )
        ).scalars()
    )
    preferences = (
        await db.execute(
            select(UserPreference)
            .options(
                load_only(
                    UserPreference.theme,
                    UserPreference.motion_preference,
                    UserPreference.default_module_id,
                    UserPreference.default_enrollment_id,
                    UserPreference.daily_review_target,
                    UserPreference.reminder_daily_review,
                    UserPreference.reminder_processing_attention,
                    UserPreference.reminder_paper_review,
                    UserPreference.reminder_health_attention,
                    raiseload=True,
                ),
                raiseload("*"),
            )
            .where(UserPreference.user_id == user.id)
        )
    ).scalar_one_or_none()

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
                            "default_enrollment_id": preferences.default_enrollment_id,
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
                for chunk in sorted(source.chunks, key=lambda item: item.chunk_index)
                if is_active_source_chunk(chunk, source)
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
                f"{base}/original/{_safe_component(paper.filename)}",
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
                        "auth_method": item.auth_method,
                        "provider_account_label": item.provider_account_label,
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
