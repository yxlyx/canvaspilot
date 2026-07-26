from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.flashcard import LearningEvidence
from app.models.m3 import SourceChange, StudyOutput, WikiRevision
from app.models.processing import ProcessingEvent, ProcessingRun
from app.models.source import Source, SourceStatus
from app.models.user import User


async def activity_entries(user: User, db: AsyncSession, limit: int) -> list[dict]:
    per_source = min(limit, 100)
    revisions = list(
        (
            await db.execute(
                select(WikiRevision)
                .where(WikiRevision.user_id == user.id)
                .order_by(WikiRevision.created_at.desc())
                .limit(per_source)
            )
        ).scalars()
    )
    changes = list(
        (
            await db.execute(
                select(SourceChange)
                .where(SourceChange.user_id == user.id)
                .order_by(SourceChange.created_at.desc())
                .limit(per_source)
            )
        ).scalars()
    )
    evidence = list(
        (
            await db.execute(
                select(LearningEvidence)
                .where(LearningEvidence.user_id == user.id)
                .order_by(LearningEvidence.occurred_at.desc())
                .limit(per_source)
            )
        ).scalars()
    )
    outputs = list(
        (
            await db.execute(
                select(StudyOutput)
                .where(StudyOutput.user_id == user.id)
                .order_by(StudyOutput.created_at.desc())
                .limit(per_source)
            )
        ).scalars()
    )
    processing_events = list(
        (
            await db.execute(
                select(ProcessingEvent, ProcessingRun.source_id)
                .join(ProcessingRun, ProcessingRun.id == ProcessingEvent.run_id)
                .where(
                    ProcessingEvent.user_id == user.id,
                    ProcessingEvent.event_type.in_(["run_ready", "stage_failed", "stage_paused"]),
                )
                .order_by(ProcessingEvent.created_at.desc())
                .limit(per_source)
            )
        ).all()
    )
    failed_sources = list(
        (
            await db.execute(
                select(Source)
                .where(Source.user_id == user.id, Source.status == SourceStatus.FAILED)
                .order_by(Source.updated_at.desc())
                .limit(per_source)
            )
        ).scalars()
    )
    entries = [
        {
            "id": item.id,
            "event_type": "wiki_revision",
            "category": "content",
            "title": item.title,
            "summary": item.change_summary or f"Revision {item.revision_number}",
            "href": f"/wiki/activity?page={item.page_id}",
            "resource_id": item.page_id,
            "created_at": item.created_at,
            "revision_number": item.revision_number,
        }
        for item in revisions
    ]
    entries += [
        {
            "id": item.id,
            "event_type": "source_change",
            "category": "content",
            "title": item.source_title or "Source update",
            "summary": item.change_type.replace("_", " ").capitalize(),
            "href": "/sources",
            "resource_id": item.source_id,
            "created_at": item.created_at,
        }
        for item in changes
    ]
    entries += [
        {
            "id": item.id,
            "event_type": (
                "paper_evidence" if item.evidence_type == "marked_paper" else "flashcard_evidence"
            ),
            "category": "evidence",
            "title": item.topic_tag.replace("-", " ").title(),
            "summary": (
                "Reviewed marked-paper evidence"
                if item.evidence_type == "marked_paper"
                else "Reviewed a flashcard"
            ),
            "href": "/sources/papers" if item.evidence_type == "marked_paper" else "/flashcards",
            "resource_id": item.marked_paper_question_id or item.flashcard_id,
            "created_at": item.occurred_at,
        }
        for item in evidence
    ]
    entries += [
        {
            "id": item.id,
            "event_type": item.output_type,
            "category": "study_guides",
            "title": item.title,
            "summary": item.message or item.status.replace("_", " ").capitalize(),
            "href": f"/wiki/guides/{item.id}",
            "resource_id": item.id,
            "created_at": item.created_at,
        }
        for item in outputs
    ]
    entries += [
        {
            "id": item.id,
            "event_type": "processing_event",
            "category": "content",
            "title": item.event_type.replace("_", " ").title(),
            "summary": str(
                item.payload.get("status")
                or item.payload.get("error_code")
                or "Source pipeline updated"
            ),
            "href": f"/sources?run={item.run_id}",
            "resource_id": source_id,
            "created_at": item.created_at,
        }
        for item, source_id in processing_events
    ]
    entries += [
        {
            "id": item.id,
            "event_type": "processing_failure",
            "category": "content",
            "title": item.title,
            "summary": item.import_error or "Source processing needs attention",
            "href": "/sources?status=failed",
            "resource_id": item.id,
            "created_at": item.updated_at,
        }
        for item in failed_sources
    ]
    return sorted(
        entries,
        key=lambda entry: (entry["created_at"], str(entry["id"])),
        reverse=True,
    )[:limit]
