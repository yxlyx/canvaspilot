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
    events_by_run: dict[object, list[tuple]] = {}
    for item, source_id in processing_events:
        events_by_run.setdefault(item.run_id, []).append((item, source_id))
    attention_sources: set[object] = set()
    for run_events in events_by_run.values():
        ready = next((pair for pair in run_events if pair[0].event_type == "run_ready"), None)
        interruption = next(
            (pair for pair in run_events if pair[0].event_type in {"stage_failed", "stage_paused"}),
            None,
        )
        item, source_id = ready or run_events[0]
        if ready and interruption:
            title = "Source processing recovered"
            summary = "An earlier interruption was resolved; the source is ready now."
            event_type = "processing_recovered"
        elif item.event_type == "run_ready":
            title = "Source processing completed"
            summary = "The source is indexed and its available learning material is ready."
            event_type = "processing_completed"
        elif item.event_type == "stage_paused":
            title = "Source processing paused"
            summary = "Saved work is safe. Open the run to resolve the requirement and retry."
            event_type = "processing_attention"
        else:
            title = "Source processing needs attention"
            summary = (
                "A stage stopped before completion. Open the run to review the reason and retry."
            )
            event_type = "processing_attention"
        if event_type == "processing_attention":
            attention_sources.add(source_id)
        entries.append(
            {
                "id": item.id,
                "event_type": event_type,
                "category": "content",
                "title": title,
                "summary": summary,
                "href": f"/sources?run={item.run_id}",
                "resource_id": source_id,
                "created_at": item.created_at,
            }
        )
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
        if item.id not in attention_sources
    ]
    return sorted(
        entries,
        key=lambda entry: (entry["created_at"], str(entry["id"])),
        reverse=True,
    )[:limit]
