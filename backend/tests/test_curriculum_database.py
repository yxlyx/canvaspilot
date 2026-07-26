import asyncio
import uuid
from collections.abc import AsyncGenerator

import pytest
from sqlalchemy import delete, func, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError, WikiBaseError
from app.models.curriculum import (
    CatalogModule,
    CurriculumTopic,
    ModuleEnrollment,
    ProviderModuleSnapshot,
    TopicRevision,
)
from app.models.source import Source, SourceKind, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.routers.curriculum import list_enrollments, list_topics
from app.schemas.curriculum import TopicListUpdate
from app.schemas.settings import UserPreferenceUpdateRequest
from app.schemas.sources import SourceCreate
from app.services.curriculum import (
    commit_import_preview,
    create_import_preview,
    propose_syllabus_refinement,
    review_topic_revision,
    save_reviewed_topics,
)
from app.services.preferences import update_preferences
from app.services.source_parsers import parse_markdown
from app.services.sources import create_or_update_source


class FakeNUSModsClient:
    def __init__(self):
        self.titles = {"CS1010": "Programming", "MA1521": "Calculus"}
        self.descriptions = {
            "CS1010": "Algorithms and programs; data structures and testing.",
            "MA1521": "Limits and continuity; differentiation and integration.",
        }

    async def module(self, _academic_year: str, code: str) -> dict | None:
        if code not in self.titles:
            return None
        return {
            "moduleCode": code,
            "title": self.titles[code],
            "description": self.descriptions[code],
            "semesterData": [{"semester": 1}],
        }


async def _require_curriculum_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT import_method FROM module_enrollments LIMIT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"migrated curriculum database is unavailable: {exc}")


@pytest.fixture
async def curriculum_session() -> AsyncGenerator[tuple[AsyncSession, User, User], None]:
    from app.db.database import async_session_factory, engine

    await engine.dispose()
    async with async_session_factory() as session:
        await _require_curriculum_database(session)
        await session.execute(delete(CatalogModule))
        await session.execute(delete(ProviderModuleSnapshot))
        await session.commit()
        user_ids = [uuid.uuid4(), uuid.uuid4()]
        users = [
            User(
                id=user_ids[0],
                name="Curriculum User",
                email=f"curriculum-{user_ids[0]}@example.com",
            ),
            User(
                id=user_ids[1],
                name="Other Curriculum User",
                email=f"curriculum-{user_ids[1]}@example.com",
            ),
        ]
        session.add_all(users)
        await session.commit()
        try:
            yield session, users[0], users[1]
        finally:
            await session.rollback()
            await session.execute(delete(User).where(User.id.in_(user_ids)))
            await session.execute(delete(CatalogModule))
            await session.execute(delete(ProviderModuleSnapshot))
            await session.commit()
    await engine.dispose()


async def _preview(
    session: AsyncSession,
    user: User,
    client: FakeNUSModsClient,
    codes: list[str],
    academic_year: str = "2024-2025",
):
    return await create_import_preview(
        user=user,
        academic_year=academic_year,
        semester=1,
        share_url=None,
        manual_codes=codes,
        db=session,
        client=client,
    )


@pytest.mark.database
async def test_preview_selection_snapshot_idempotency_and_user_isolation(
    curriculum_session: tuple[AsyncSession, User, User],
):
    session, user, other_user = curriculum_session
    client = FakeNUSModsClient()
    preview = await _preview(session, user, client, ["CS1010", "MA1521"])

    assert preview.reconciliation == {
        "added": ["CS1010", "MA1521"],
        "unchanged": [],
        "removed": [],
        "ambiguous": [],
    }
    assert all(item.payload_sha256 and item.detail_snapshot for item in preview.items)
    client.titles["CS1010"] = "Mutable provider title"
    first = await commit_import_preview(
        preview_id=preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )
    repeated = await commit_import_preview(
        preview_id=preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )

    assert first == repeated
    assert first.items[0].status == "imported"
    assert (
        await session.scalar(select(CatalogModule.title).where(CatalogModule.code == "CS1010"))
        == "Programming"
    )
    assert (
        await session.scalar(
            select(func.count(ModuleEnrollment.id)).where(ModuleEnrollment.user_id == user.id)
        )
        == 1
    )
    assert (
        await session.scalar(
            select(func.count(ModuleEnrollment.id)).where(ModuleEnrollment.user_id == other_user.id)
        )
        == 0
    )
    enrollment = await session.get(ModuleEnrollment, first.items[0].enrollment_id)
    assert enrollment.import_method == "manual_codes"
    assert enrollment.provenance == "nusmods"
    assert enrollment.topic_state == "provisional"
    assert enrollment.evidence_warning

    with pytest.raises(WikiBaseError) as changed_decision:
        await commit_import_preview(
            preview_id=preview.id,
            selected_codes=["MA1521"],
            user=user,
            db=session,
        )
    assert changed_decision.value.error == "preview_already_committed"
    with pytest.raises(NotFoundError):
        await commit_import_preview(
            preview_id=preview.id,
            selected_codes=["CS1010"],
            user=other_user,
            db=session,
        )


@pytest.mark.database
async def test_concurrent_commit_returns_the_same_stored_result(
    curriculum_session: tuple[AsyncSession, User, User],
):
    from app.db.database import async_session_factory

    session, user, _ = curriculum_session
    preview = await _preview(session, user, FakeNUSModsClient(), ["CS1010"])
    async with async_session_factory() as other_session:
        first, second = await asyncio.gather(
            commit_import_preview(
                preview_id=preview.id,
                selected_codes=["CS1010"],
                user=user,
                db=session,
            ),
            commit_import_preview(
                preview_id=preview.id,
                selected_codes=["CS1010"],
                user=user,
                db=other_session,
            ),
        )
    assert first == second
    assert first.items[0].status == "imported"


@pytest.mark.database
async def test_cross_user_opposite_order_concurrent_imports_do_not_deadlock(
    curriculum_session: tuple[AsyncSession, User, User],
):
    from app.db.database import async_session_factory

    session, user, other_user = curriculum_session
    first_preview = await _preview(session, user, FakeNUSModsClient(), ["CS1010", "MA1521"])
    second_preview = await _preview(
        session,
        other_user,
        FakeNUSModsClient(),
        ["MA1521", "CS1010"],
        academic_year="2025-2026",
    )

    async with async_session_factory() as other_session:
        first, second = await asyncio.wait_for(
            asyncio.gather(
                commit_import_preview(
                    preview_id=first_preview.id,
                    selected_codes=["CS1010", "MA1521"],
                    user=user,
                    db=session,
                ),
                commit_import_preview(
                    preview_id=second_preview.id,
                    selected_codes=["MA1521", "CS1010"],
                    user=other_user,
                    db=other_session,
                ),
            ),
            timeout=5,
        )

    assert [item.code for item in first.items] == ["CS1010", "MA1521"]
    assert [item.code for item in second.items] == ["MA1521", "CS1010"]
    assert all(item.status == "imported" for result in (first, second) for item in result.items)


@pytest.mark.database
async def test_concurrent_selected_archive_inversion_does_not_deadlock(
    curriculum_session: tuple[AsyncSession, User, User],
):
    from app.db.database import async_session_factory

    session, user, _ = curriculum_session
    client = FakeNUSModsClient()
    initial = await _preview(session, user, client, ["CS1010", "MA1521"])
    await commit_import_preview(
        preview_id=initial.id,
        selected_codes=["CS1010", "MA1521"],
        user=user,
        db=session,
    )
    first_preview = await _preview(session, user, client, ["CS1010"])
    second_preview = await _preview(session, user, client, ["MA1521"])

    async with async_session_factory() as other_session:
        first, second = await asyncio.wait_for(
            asyncio.gather(
                commit_import_preview(
                    preview_id=first_preview.id,
                    selected_codes=["CS1010"],
                    archive_codes=["MA1521"],
                    user=user,
                    db=session,
                ),
                commit_import_preview(
                    preview_id=second_preview.id,
                    selected_codes=["MA1521"],
                    archive_codes=["CS1010"],
                    user=user,
                    db=other_session,
                ),
            ),
            timeout=5,
        )

    assert [item.status for item in first.items[1:]] == ["archived"]
    assert [item.status for item in second.items[1:]] == ["archived"]
    assert sorted([first.items[0].status, second.items[0].status]) == [
        "already_enrolled",
        "restored",
    ]
    session.expire_all()
    assert (
        await session.scalar(
            select(func.count(ModuleEnrollment.id)).where(ModuleEnrollment.archived.is_(True))
        )
        == 1
    )


@pytest.mark.database
async def test_same_module_years_keep_exact_offering_snapshot_provenance_and_topics(
    curriculum_session: tuple[AsyncSession, User, User],
):
    session, user, other_user = curriculum_session
    client = FakeNUSModsClient()
    client.descriptions["CS1010"] = "First-year arrays; first-year recursion."
    first_preview = await _preview(session, user, client, ["CS1010"], academic_year="2024-2025")
    first_item = first_preview.items[0]
    first_provenance = (
        first_item.provider_version,
        first_item.source_url,
        first_item.fetched_at,
        first_item.payload_sha256,
    )
    first_hash = first_item.payload_sha256
    first = await commit_import_preview(
        preview_id=first_preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )

    client.descriptions["CS1010"] = "Refetched content must not replace first-year provenance."
    refetched_preview = await _preview(session, user, client, ["CS1010"], academic_year="2024-2025")
    assert refetched_preview.items[0].payload_sha256 != first_hash
    refetched = await commit_import_preview(
        preview_id=refetched_preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )
    assert refetched.items[0].status == "already_enrolled"

    other_preview = await _preview(
        session, other_user, client, ["CS1010"], academic_year="2024-2025"
    )
    other = await commit_import_preview(
        preview_id=other_preview.id,
        selected_codes=["CS1010"],
        user=other_user,
        db=session,
    )
    assert other.items[0].status == "imported"

    client.descriptions["CS1010"] = "Second-year graphs; second-year dynamic programming."
    second_preview = await _preview(session, user, client, ["CS1010"], academic_year="2025-2026")
    second_item = second_preview.items[0]
    second_provenance = (
        second_item.provider_version,
        second_item.source_url,
        second_item.fetched_at,
        second_item.payload_sha256,
    )
    second = await commit_import_preview(
        preview_id=second_preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )

    session.expire_all()
    await session.refresh(user)
    await session.refresh(other_user)
    enrollments = await list_enrollments(user=user, db=session)
    other_enrollments = await list_enrollments(user=other_user, db=session)
    by_year = {enrollment.academic_year: enrollment for enrollment in enrollments}
    assert by_year["2024-2025"].provider_academic_year == "2024-2025"
    assert (
        by_year["2024-2025"].provider_version,
        by_year["2024-2025"].source_url,
        by_year["2024-2025"].provider_fetched_at,
        by_year["2024-2025"].payload_sha256,
    ) == first_provenance
    assert by_year["2025-2026"].provider_academic_year == "2025-2026"
    assert (
        by_year["2025-2026"].provider_version,
        by_year["2025-2026"].source_url,
        by_year["2025-2026"].provider_fetched_at,
        by_year["2025-2026"].payload_sha256,
    ) == second_provenance
    assert len(other_enrollments) == 1
    assert other_enrollments[0].payload_sha256 == first_hash
    first_topics = await list_topics(first.items[0].enrollment_id, user=user, db=session)
    other_topics = await list_topics(other.items[0].enrollment_id, user=other_user, db=session)
    second_topics = await list_topics(second.items[0].enrollment_id, user=user, db=session)
    assert [topic.title for topic in first_topics] == ["First-year arrays", "first-year recursion"]
    assert [topic.title for topic in other_topics] == ["First-year arrays", "first-year recursion"]
    assert [topic.title for topic in second_topics] == [
        "Second-year graphs",
        "second-year dynamic programming",
    ]


@pytest.mark.database
async def test_concurrent_different_previews_seed_only_the_winning_snapshot(
    curriculum_session: tuple[AsyncSession, User, User],
):
    from app.db.database import async_session_factory

    session, user, _ = curriculum_session
    first_client = FakeNUSModsClient()
    second_client = FakeNUSModsClient()
    first_client.descriptions["CS1010"] = "First snapshot topic; first-only evidence."
    second_client.descriptions["CS1010"] = "Second snapshot topic; second-only evidence."
    first_preview = await _preview(session, user, first_client, ["CS1010"])
    second_preview = await _preview(session, user, second_client, ["CS1010"])

    async with async_session_factory() as other_session:
        results = await asyncio.gather(
            commit_import_preview(
                preview_id=first_preview.id,
                selected_codes=["CS1010"],
                user=user,
                db=session,
            ),
            commit_import_preview(
                preview_id=second_preview.id,
                selected_codes=["CS1010"],
                user=user,
                db=other_session,
            ),
        )

    assert sorted(result.items[0].status for result in results) == [
        "already_enrolled",
        "imported",
    ]
    enrollment_id = results[0].items[0].enrollment_id
    topics = list(
        (
            await session.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment_id)
                .order_by(CurriculumTopic.position)
            )
        ).scalars()
    )
    assert [topic.position for topic in topics] == list(range(len(topics)))
    assert len({topic.source_text for topic in topics}) == 1
    assert topics[0].source_text in {
        "First snapshot topic; first-only evidence.",
        "Second snapshot topic; second-only evidence.",
    }


@pytest.mark.database
async def test_preview_snapshot_hash_tampering_fails_before_mutation(
    curriculum_session: tuple[AsyncSession, User, User],
):
    session, user, _ = curriculum_session
    preview = await _preview(session, user, FakeNUSModsClient(), ["CS1010"])
    preview.items[0].detail_snapshot = {
        **preview.items[0].detail_snapshot,
        "description": "Tampered after preview persistence.",
    }

    with pytest.raises(WikiBaseError) as error:
        await commit_import_preview(
            preview_id=preview.id,
            selected_codes=["CS1010"],
            user=user,
            db=session,
        )

    assert error.value.error == "invalid_preview_snapshot"
    assert await session.scalar(select(func.count(ModuleEnrollment.id))) == 0


@pytest.mark.database
async def test_preview_rejects_tampering_and_requires_explicit_archive_restore(
    curriculum_session: tuple[AsyncSession, User, User],
):
    session, user, _ = curriculum_session
    client = FakeNUSModsClient()
    initial = await _preview(session, user, client, ["CS1010", "MA1521"])
    imported = await commit_import_preview(
        preview_id=initial.id,
        selected_codes=["CS1010", "MA1521"],
        user=user,
        db=session,
    )
    enrollment_ids = {item.code: item.enrollment_id for item in imported.items}

    reconciliation = await _preview(session, user, client, ["CS1010"])
    assert reconciliation.reconciliation["unchanged"] == ["CS1010"]
    assert reconciliation.reconciliation["removed"] == ["MA1521"]
    with pytest.raises(WikiBaseError) as tampered:
        await commit_import_preview(
            preview_id=reconciliation.id,
            selected_codes=["NOTINPREVIEW"],
            user=user,
            db=session,
        )
    assert tampered.value.error == "invalid_selection"
    assert not (await session.get(ModuleEnrollment, enrollment_ids["MA1521"])).archived

    committed = await commit_import_preview(
        preview_id=reconciliation.id,
        selected_codes=["CS1010"],
        archive_codes=["MA1521"],
        user=user,
        db=session,
    )
    assert [item.status for item in committed.items] == ["already_enrolled", "archived"]
    assert (await session.get(ModuleEnrollment, enrollment_ids["MA1521"])).archived

    restore_preview = await _preview(session, user, client, ["MA1521"])
    assert restore_preview.items[0].disposition == "restore"
    restored = await commit_import_preview(
        preview_id=restore_preview.id,
        selected_codes=["MA1521"],
        user=user,
        db=session,
    )
    assert restored.items[0].status == "restored"
    assert not (await session.get(ModuleEnrollment, enrollment_ids["MA1521"])).archived


@pytest.mark.database
async def test_topic_multi_removal_history_and_parser_derived_revision_are_atomic(
    curriculum_session: tuple[AsyncSession, User, User],
):
    session, user, _ = curriculum_session
    client = FakeNUSModsClient()
    preview = await _preview(session, user, client, ["CS1010"])
    committed = await commit_import_preview(
        preview_id=preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )
    enrollment = await session.get(ModuleEnrollment, committed.items[0].enrollment_id)
    seeded = list(
        (
            await session.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment.id)
                .order_by(CurriculumTopic.position)
            )
        ).scalars()
    )
    original_id = seeded[0].id
    reviewed = await save_reviewed_topics(
        enrollment,
        TopicListUpdate(
            topics=[
                {"id": original_id, "title": "Reviewed algorithms"},
                {"title": "Complexity analysis"},
                {"title": "Program correctness"},
                {"title": "Testing strategy"},
            ]
        ),
        session,
    )
    await session.commit()
    assert reviewed[0].id == original_id
    assert reviewed[0].state == "canonical"
    assert reviewed[0].provenance == "user_review"

    reduced = await save_reviewed_topics(
        enrollment,
        TopicListUpdate(topics=[{"id": original_id, "title": "Reviewed algorithms"}]),
        session,
    )
    await session.commit()
    assert [topic.position for topic in reduced] == list(range(len(reduced)))
    assert sum(topic.archived for topic in reduced) >= 3
    revisions = list(
        (
            await session.execute(
                select(TopicRevision)
                .where(
                    TopicRevision.enrollment_id == enrollment.id,
                    TopicRevision.algorithm == "manual-review-v1",
                )
                .order_by(TopicRevision.created_at)
            )
        ).scalars()
    )
    assert len(revisions) == 2
    assert revisions[-1].mapping["archived"]
    assert revisions[-1].base_topics != revisions[-1].proposed_topics
    seeded_snapshot = revisions[0].base_topics[0]
    assert seeded_snapshot["source_text"] == (
        "Algorithms and programs; data structures and testing."
    )
    assert seeded_snapshot["source_sha256"]
    assert seeded_snapshot["extraction_rule_hash"]
    assert seeded_snapshot["evidence_warning"]

    source = Source(
        user_id=user.id,
        source_type=SourceKind.MARKDOWN,
        origin="manual",
        title="Syllabus",
        citation_label="Syllabus",
        status=SourceStatus.READY,
    )
    session.add(source)
    await session.flush()
    sections = parse_markdown(
        """# Course syllabus
Overview.

## Week 1: Algorithms
Complexity.

## Week 2: Testing
Correctness.
"""
    )
    for index, section in enumerate(sections):
        session.add(
            SourceChunk(
                source_id=source.id,
                chunk_index=index,
                citation_ref=f"syllabus:{index + 1}",
                location_label=section.location_label,
                content=section.content,
                token_count=len(section.content.split()),
            )
        )
    await session.commit()
    revision = await propose_syllabus_refinement(
        enrollment=enrollment, source_id=source.id, user=user, db=session
    )
    await session.commit()
    assert [item["title"] for item in revision.proposed_topics] == [
        "Course syllabus",
        "Week 1: Algorithms",
        "Week 2: Testing",
    ]
    assert all(chunk["location_label"] for chunk in revision.mapping["source_chunks"])
    competing_revision = await propose_syllabus_refinement(
        enrollment=enrollment, source_id=source.id, user=user, db=session
    )
    await session.commit()

    accepted = await review_topic_revision(
        enrollment=enrollment,
        revision_id=revision.id,
        decision="accept",
        user=user,
        db=session,
    )
    await session.commit()
    assert accepted.status == "accepted"
    assert enrollment.topic_state == "canonical"
    assert enrollment.evidence_warning is None
    assert not set(accepted.mapping["accepted_topics"]) & set(accepted.mapping["archived_topics"])
    assert set(accepted.mapping["superseded_topics"]) == {
        item["id"] for item in accepted.base_topics
    }

    with pytest.raises(WikiBaseError) as competing_stale:
        await review_topic_revision(
            enrollment=enrollment,
            revision_id=competing_revision.id,
            decision="accept",
            user=user,
            db=session,
        )
    assert competing_stale.value.error == "revision_stale"
    await session.commit()

    manual_stale = await propose_syllabus_refinement(
        enrollment=enrollment, source_id=source.id, user=user, db=session
    )
    await session.commit()
    current_topic = await session.scalar(
        select(CurriculumTopic)
        .where(
            CurriculumTopic.enrollment_id == enrollment.id,
            CurriculumTopic.archived.is_(False),
        )
        .order_by(CurriculumTopic.position)
    )
    await save_reviewed_topics(
        enrollment,
        TopicListUpdate(topics=[{"id": current_topic.id, "title": "Manual override"}]),
        session,
    )
    await session.commit()
    with pytest.raises(WikiBaseError) as manual_edit_stale:
        await review_topic_revision(
            enrollment=enrollment,
            revision_id=manual_stale.id,
            decision="accept",
            user=user,
            db=session,
        )
    assert manual_edit_stale.value.error == "revision_stale"
    await session.commit()

    with pytest.raises(WikiBaseError) as repeated:
        await review_topic_revision(
            enrollment=enrollment,
            revision_id=revision.id,
            decision="reject",
            user=user,
            db=session,
        )
    assert repeated.value.error == "revision_already_reviewed"


@pytest.mark.database
async def test_syllabus_revision_detects_changes_after_bounded_extraction_chunks(
    curriculum_session: tuple[AsyncSession, User, User],
):
    session, user, _ = curriculum_session
    preview = await _preview(session, user, FakeNUSModsClient(), ["CS1010"])
    committed = await commit_import_preview(
        preview_id=preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )
    enrollment = await session.get(ModuleEnrollment, committed.items[0].enrollment_id)
    source = Source(
        user_id=user.id,
        source_type=SourceKind.MARKDOWN,
        origin="manual",
        title="Long syllabus",
        citation_label="Long syllabus",
        status=SourceStatus.READY,
    )
    session.add(source)
    await session.flush()
    session.add_all(
        [
            SourceChunk(
                source_id=source.id,
                chunk_index=index,
                citation_ref=f"syllabus:{index + 1}",
                location_label="Course syllabus" if index == 0 else "",
                content=f"Plain syllabus content {index}",
                token_count=4,
            )
            for index in range(502)
        ]
    )
    await session.commit()

    revision = await propose_syllabus_refinement(
        enrollment=enrollment, source_id=source.id, user=user, db=session
    )
    await session.commit()
    assert len(revision.mapping["source_chunks"]) == 500
    assert revision.mapping["source_chunk_count"] == 502

    late_chunk = await session.scalar(
        select(SourceChunk).where(
            SourceChunk.source_id == source.id,
            SourceChunk.chunk_index == 500,
        )
    )
    late_chunk.content = "Changed after the extraction boundary"
    await session.commit()

    with pytest.raises(WikiBaseError) as stale:
        await review_topic_revision(
            enrollment=enrollment,
            revision_id=revision.id,
            decision="accept",
            user=user,
            db=session,
        )
    assert stale.value.error == "revision_stale"


@pytest.mark.database
async def test_source_reattachment_serializes_with_revision_acceptance_and_scope_is_enforced(
    curriculum_session: tuple[AsyncSession, User, User],
):
    from app.db.database import async_session_factory

    session, user, _ = curriculum_session
    preview = await _preview(session, user, FakeNUSModsClient(), ["CS1010", "MA1521"])
    committed = await commit_import_preview(
        preview_id=preview.id,
        selected_codes=["CS1010", "MA1521"],
        user=user,
        db=session,
    )
    enrollment_ids = {item.code: item.enrollment_id for item in committed.items}
    enrollment = await session.get(ModuleEnrollment, enrollment_ids["CS1010"])
    other_enrollment = await session.get(ModuleEnrollment, enrollment_ids["MA1521"])
    source = Source(
        user_id=user.id,
        enrollment_id=enrollment.id,
        source_type=SourceKind.MARKDOWN,
        origin="manual",
        title="Concurrent syllabus",
        citation_label="Concurrent syllabus",
        status=SourceStatus.READY,
    )
    session.add(source)
    await session.flush()
    session.add(
        SourceChunk(
            source_id=source.id,
            chunk_index=0,
            citation_ref="syllabus:1",
            location_label="Replacement syllabus",
            content="# Replacement syllabus",
            token_count=3,
        )
    )
    await session.commit()
    source_id = source.id

    with pytest.raises(NotFoundError):
        await propose_syllabus_refinement(
            enrollment=other_enrollment,
            source_id=source_id,
            user=user,
            db=session,
        )
    await session.rollback()
    await session.refresh(user)
    enrollment = await session.get(ModuleEnrollment, enrollment_ids["CS1010"])
    other_enrollment = await session.get(ModuleEnrollment, enrollment_ids["MA1521"])

    revision = await propose_syllabus_refinement(
        enrollment=enrollment,
        source_id=source_id,
        user=user,
        db=session,
    )
    await session.commit()
    original_titles = [
        topic.title
        for topic in (
            await session.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment.id)
                .order_by(CurriculumTopic.position)
            )
        ).scalars()
    ]
    moved = asyncio.Event()
    release_move = asyncio.Event()

    async def move_source() -> None:
        async with async_session_factory() as other_session:
            await other_session.execute(
                select(func.pg_advisory_xact_lock(func.hashtextextended(f"source:{source_id}", 0)))
            )
            moving_source = await other_session.get(Source, source_id, with_for_update=True)
            moving_source.enrollment_id = other_enrollment.id
            moved.set()
            await release_move.wait()
            await other_session.commit()

    move_task = asyncio.create_task(move_source())
    await moved.wait()
    accept_task = asyncio.create_task(
        review_topic_revision(
            enrollment=enrollment,
            revision_id=revision.id,
            decision="accept",
            user=user,
            db=session,
        )
    )
    await asyncio.sleep(0.05)
    assert not accept_task.done()
    release_move.set()
    await move_task
    with pytest.raises(WikiBaseError) as stale:
        await accept_task
    assert stale.value.error == "revision_stale"
    await session.rollback()

    current_titles = [
        topic.title
        for topic in (
            await session.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment_ids["CS1010"])
                .order_by(CurriculumTopic.position)
            )
        ).scalars()
    ]
    assert current_titles == original_titles


@pytest.mark.database
async def test_default_enrollment_scope_is_owned_active_and_distinct_from_modules(
    curriculum_session: tuple[AsyncSession, User, User],
):
    session, user, other_user = curriculum_session
    preview = await _preview(session, user, FakeNUSModsClient(), ["CS1010"])
    committed = await commit_import_preview(
        preview_id=preview.id,
        selected_codes=["CS1010"],
        user=user,
        db=session,
    )
    enrollment_id = committed.items[0].enrollment_id

    preferences = await update_preferences(
        user,
        UserPreferenceUpdateRequest(
            default_module_id=None,
            default_enrollment_id=enrollment_id,
            daily_review_target=12,
        ),
        session,
    )
    assert preferences.default_enrollment_id == enrollment_id
    assert preferences.default_module_id is None

    source = await create_or_update_source(
        user,
        SourceCreate(
            enrollment_id=enrollment_id,
            source_type=SourceKind.MARKDOWN,
            origin="manual",
            title="Scoped notes",
        ),
        session,
    )
    assert source.enrollment_id == enrollment_id
    with pytest.raises(NotFoundError):
        await create_or_update_source(
            other_user,
            SourceCreate(
                enrollment_id=enrollment_id,
                source_type=SourceKind.MARKDOWN,
                origin="manual",
                title="Wrong owner notes",
            ),
            session,
        )

    with pytest.raises(NotFoundError):
        await update_preferences(
            other_user,
            UserPreferenceUpdateRequest(default_enrollment_id=enrollment_id),
            session,
        )

    enrollment = await session.get(ModuleEnrollment, enrollment_id)
    enrollment.archived = True
    await session.commit()
    with pytest.raises(NotFoundError):
        await update_preferences(
            user,
            UserPreferenceUpdateRequest(default_enrollment_id=enrollment_id),
            session,
        )
