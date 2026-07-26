import asyncio
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import delete, event, func, select, text
from sqlalchemy.exc import SQLAlchemyError

from app.exceptions import WikiBaseError
from app.models.curriculum import (
    CatalogModule,
    CurriculumTopic,
    ModuleEnrollment,
    ProviderModuleSnapshot,
    SemesterOffering,
    TopicSourceAssociation,
)
from app.models.flashcard import Flashcard, FlashcardAttempt, FlashcardDeck
from app.models.source import Source, SourceKind, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.services.curriculum_coverage import (
    coverage_dashboard,
    decide_association,
    generate_proposals,
    remove_confirmed_association,
    selectable_evidence_chunks,
)
from app.services.learning_metrics import enrollment_learning_metrics


@pytest.fixture
async def coverage_records():
    from app.db.database import async_session_factory, engine

    await engine.dispose()
    async with async_session_factory() as session:
        try:
            await session.execute(text("SELECT 1 FROM topic_source_associations LIMIT 1"))
        except (OSError, SQLAlchemyError) as exc:
            pytest.fail(f"configured migrated coverage database is unavailable: {exc}")
        suffix = uuid.uuid4().hex[:8].upper()
        user = User(id=uuid.uuid4(), name="Coverage User", email=f"coverage-{suffix}@example.com")
        catalog = CatalogModule(
            id=uuid.uuid4(),
            institution="Test University",
            canonical_code=f"T{suffix}",
            code=f"T{suffix}",
            title="Coverage",
            description="Coverage fixture",
            metadata_json={},
        )
        snapshot = ProviderModuleSnapshot(
            id=uuid.uuid4(),
            provider="fixture",
            academic_year="2025-2026",
            module_code=f"T{suffix}",
            provider_version="v1",
            source_url="https://example.test/module",
            fetched_at=datetime.now(UTC),
            payload_sha256="a" * 64,
            payload={"title": "Coverage"},
        )
        offering = SemesterOffering(
            id=uuid.uuid4(),
            catalog_module=catalog,
            provider_snapshot=snapshot,
            academic_year="2025-2026",
            semester=1,
            metadata_json={},
        )
        enrollment = ModuleEnrollment(
            id=uuid.uuid4(),
            user_id=user.id,
            offering=offering,
            provenance="manual",
            import_method="manual_codes",
            topic_state="canonical",
            lesson_config={},
        )
        topics = [
            CurriculumTopic(
                id=uuid.uuid4(),
                enrollment_id=enrollment.id,
                position=position,
                title=title,
                state="canonical",
                provenance="user_review",
                extraction_rule="manual-review-v1",
                extraction_rule_hash="b" * 64,
                source_text=title,
                source_sha256=str(position) * 64,
            )
            for position, title in enumerate(["Graph traversal", "Matrix factorisation"])
        ]
        source = Source(
            id=uuid.uuid4(),
            user_id=user.id,
            enrollment_id=None,
            source_type=SourceKind.PDF,
            origin="upload",
            title="Algorithms notes",
            citation_label="Algorithms notes",
            status=SourceStatus.READY,
            topic_tags=[],
        )
        chunks = [
            SourceChunk(
                id=uuid.uuid4(),
                source_id=source.id,
                chunk_index=0,
                citation_ref="Lecture 3, p. 8",
                location_label="Graphs",
                content="Graph traversal visits vertices using breadth first search.",
                token_count=8,
                embedding=None,
            ),
            SourceChunk(
                id=uuid.uuid4(),
                source_id=source.id,
                chunk_index=1,
                citation_ref="Lecture 8, p. 2",
                location_label="Linear algebra",
                content="Matrix factorisation decomposes a matrix into useful factors.",
                token_count=8,
                embedding=None,
            ),
        ]
        session.add_all([user, catalog, snapshot, offering, enrollment])
        await session.flush()
        session.add_all([*topics, source])
        await session.flush()
        session.add_all(chunks)
        await session.flush()
        try:
            yield session, user, enrollment, topics, source, chunks
        finally:
            await session.rollback()
    await engine.dispose()


@pytest.mark.database
async def test_confirmed_only_coverage_lifecycle_idempotency_and_stale_evidence(coverage_records):
    session, user, enrollment, topics, source, chunks = coverage_records
    first = await generate_proposals(enrollment, [source.id], user, session)
    assert (first["created"], first["updated"], first["protected_decisions"]) == (2, 0, 0)
    repeated = await generate_proposals(enrollment, [], user, session)
    assert repeated["created"] == 0
    assert repeated["unchanged"] == 2

    dashboard = await coverage_dashboard(enrollment, session)
    assert (dashboard["numerator"], dashboard["denominator"], dashboard["percentage"]) == (
        0,
        2,
        0.0,
    )
    assert [row["state"] for row in dashboard["topics"]] == ["review", "review"]

    graph_association = next(row for row in first["associations"] if row.topic_id == topics[0].id)
    await decide_association(enrollment, graph_association.id, "confirm", user, session)
    dashboard = await coverage_dashboard(enrollment, session)
    assert dashboard["numerator"] == 1
    assert dashboard["percentage"] == 50.0
    assert dashboard["disclosure"] == "source_coverage_not_mastery"

    recomputed = await generate_proposals(enrollment, [], user, session)
    assert recomputed["protected_decisions"] == 1
    assert graph_association.status == "confirmed"

    chunks[1].content = "This replacement no longer discusses the canonical topic."
    await session.flush()
    dashboard = await coverage_dashboard(enrollment, session)
    matrix = next(row for row in dashboard["topics"] if row["topic_id"] == topics[1].id)
    assert matrix["state"] == "missing"
    assert matrix["proposed_sources"][0]["stale_reason"] == "source_chunks_changed"

    await remove_confirmed_association(enrollment, graph_association.id, user, session)
    dashboard = await coverage_dashboard(enrollment, session)
    assert dashboard["numerator"] == 0
    assert graph_association.status == "rejected"
    protected = await generate_proposals(enrollment, [], user, session)
    assert protected["protected_decisions"] == 1
    assert graph_association.status == "rejected"


@pytest.mark.database
async def test_provisional_zero_and_archived_topic_denominators_are_truthful(coverage_records):
    session, _user, enrollment, topics, source, _chunks = coverage_records
    source.enrollment_id = enrollment.id
    source.status = SourceStatus.INDEXING
    dashboard = await coverage_dashboard(enrollment, session)
    assert dashboard["topics"][0]["state"] == "missing"
    assert dashboard["topics"][0]["reason_codes"] == ["source_processing"]

    enrollment.topic_state = "provisional"
    topics[0].state = "provisional"
    dashboard = await coverage_dashboard(enrollment, session)
    assert dashboard["percentage"] is None
    assert dashboard["provisional"] is True
    assert "provisional" in dashboard["warning"].lower()

    for topic in topics:
        topic.archived = True
    enrollment.topic_state = "canonical"
    dashboard = await coverage_dashboard(enrollment, session)
    assert dashboard["topics"] == []
    assert dashboard["numerator"] == dashboard["denominator"] == 0
    assert dashboard["percentage"] is None


@pytest.mark.database
async def test_authenticated_dashboard_excludes_stale_confirmation_and_enforces_ownership(
    coverage_records, client, authed_client, mock_user
):
    session, user, enrollment, topics, source, chunks = coverage_records
    first = await generate_proposals(enrollment, [source.id], user, session)
    association = next(row for row in first["associations"] if row.topic_id == topics[0].id)
    await decide_association(enrollment, association.id, "confirm", user, session)
    chunks[0].content = "The confirmed excerpt has been removed."
    await session.commit()
    mock_user.id = user.id

    response = await client.get(f"/api/enrollments/{enrollment.id}/coverage")

    assert response.status_code == 200
    payload = response.json()
    assert payload["numerator"] == 0
    graph = next(row for row in payload["topics"] if row["topic_id"] == str(topics[0].id))
    assert graph["state"] == "missing"
    assert graph["confirmed_sources"][0]["stale"] is True
    assert graph["confirmed_sources"][0]["stale_reason"] == "source_chunks_changed"

    metrics = await client.get(f"/api/enrollments/{enrollment.id}/learning-metrics")
    legacy_metrics = await client.get("/api/m3/meters", params={"enrollment_id": enrollment.id})
    assert metrics.status_code == legacy_metrics.status_code == 200
    metrics_payload = metrics.json()
    legacy_payload = legacy_metrics.json()
    for key in ("enrollment_id", "source_coverage", "recall", "activity"):
        assert metrics_payload[key] == legacy_payload[key]

    mock_user.id = uuid.uuid4()
    forbidden = await client.get(f"/api/enrollments/{enrollment.id}/coverage")
    forbidden_metrics = await client.get(f"/api/enrollments/{enrollment.id}/learning-metrics")
    forbidden_legacy = await client.get("/api/m3/meters", params={"enrollment_id": enrollment.id})
    assert (
        forbidden.status_code
        == forbidden_metrics.status_code
        == forbidden_legacy.status_code
        == 404
    )


@pytest.mark.database
async def test_candidate_chunks_are_ranked_bounded_and_exposed_only_in_owned_scope(
    coverage_records, client, authed_client, mock_user
):
    session, user, enrollment, topics, source, chunks = coverage_records
    topics[0].archived = True
    with pytest.raises(WikiBaseError) as inactive:
        await selectable_evidence_chunks(enrollment, topics[0].id, source.id, session)
    assert inactive.value.error == "invalid_topic_id"
    topics[0].archived = False
    source.status = SourceStatus.INDEXING
    with pytest.raises(WikiBaseError) as not_ready:
        await selectable_evidence_chunks(enrollment, topics[0].id, source.id, session)
    assert not_ready.value.error == "source_not_ready"
    source.status = SourceStatus.READY
    source.enrollment_id = uuid.uuid4()
    with session.no_autoflush:
        with pytest.raises(WikiBaseError) as wrong_scope:
            await selectable_evidence_chunks(enrollment, topics[0].id, source.id, session)
    assert wrong_scope.value.error == "source_scope_conflict"
    source.enrollment_id = None

    chunks[0].content = "Graph traversal " + ("detail " * 100)
    ranked = await selectable_evidence_chunks(enrollment, topics[0].id, source.id, session)
    assert [item["chunk_id"] for item in ranked] == [chunks[0].id, chunks[1].id]
    assert [item["rank"] for item in ranked] == [1, 2]
    assert ranked[0]["relevance"] == 1.0
    assert len(ranked[0]["excerpt"]) <= 322

    session.add_all(
        [
            SourceChunk(
                id=uuid.uuid4(),
                source_id=source.id,
                chunk_index=index,
                citation_ref=f"Appendix {index}",
                location_label="Appendix",
                content="Additional selectable evidence.",
                token_count=3,
                embedding=None,
            )
            for index in range(2, 105)
        ]
    )
    await session.flush()
    bounded = await selectable_evidence_chunks(enrollment, topics[0].id, source.id, session)
    assert len(bounded) == 100
    assert bounded[-1]["rank"] == 100
    assert bounded[-1]["citation"] == "Appendix 99"

    await session.commit()
    mock_user.id = user.id
    from app.db.database import engine

    queries = []

    def capture_query(_connection, _cursor, statement, _parameters, context, _executemany):
        queries.append((statement, context.execution_options))

    event.listen(engine.sync_engine, "before_cursor_execute", capture_query)
    try:
        response = await client.get(
            f"/api/enrollments/{enrollment.id}/candidate-sources/{source.id}/chunks",
            params={"topic_id": topics[0].id},
        )
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", capture_query)

    assert all("FOR UPDATE" not in statement.upper() for statement, _options in queries)
    chunk_query, chunk_options = next(
        (statement, options) for statement, options in queries if "FROM source_chunks" in statement
    )
    assert "substr(source_chunks.content" in chunk_query
    assert "source_chunks.token_count" not in chunk_query
    assert chunk_options["yield_per"] == 500
    assert response.status_code == 200
    assert response.json()[0] == {
        "chunk_id": str(chunks[0].id),
        "citation": "Lecture 3, p. 8",
        "location": "Graphs",
        "excerpt": ranked[0]["excerpt"],
        "relevance": 1.0,
        "rank": 1,
    }

    empty_source = Source(
        id=uuid.uuid4(),
        user_id=user.id,
        enrollment_id=enrollment.id,
        source_type=SourceKind.PLAIN_TEXT,
        origin="paste",
        title="Empty indexed source",
        citation_label="Empty indexed source",
        status=SourceStatus.READY,
        topic_tags=[],
    )
    session.add(empty_source)
    await session.commit()
    empty = await client.get(
        f"/api/enrollments/{enrollment.id}/candidate-sources/{empty_source.id}/chunks",
        params={"topic_id": topics[0].id},
    )
    assert empty.status_code == 200
    assert empty.json() == []

    mock_user.id = uuid.uuid4()
    hidden = await client.get(
        f"/api/enrollments/{enrollment.id}/candidate-sources/{source.id}/chunks",
        params={"topic_id": topics[0].id},
    )
    assert hidden.status_code == 404


@pytest.mark.database
async def test_concurrent_proposal_recompute_serializes_without_duplicates(coverage_records):
    session, user, enrollment, _topics, source, _chunks = coverage_records
    user_id = user.id
    enrollment_id = enrollment.id
    source_id = source.id
    catalog_id = enrollment.offering.catalog_module_id
    snapshot_id = enrollment.offering.provider_snapshot_id
    await session.commit()

    from app.db.database import async_session_factory

    async def recompute() -> tuple[int, int, int]:
        async with async_session_factory() as worker:
            worker_enrollment = await worker.scalar(
                select(ModuleEnrollment).where(ModuleEnrollment.id == enrollment_id)
            )
            worker_user = await worker.scalar(select(User).where(User.id == user_id))
            assert worker_enrollment is not None
            assert worker_user is not None
            result = await generate_proposals(worker_enrollment, [source_id], worker_user, worker)
            await worker.commit()
            return result["created"], result["updated"], result["unchanged"]

    try:
        results = await asyncio.gather(recompute(), recompute())
        assert sorted(results) == [(0, 0, 2), (2, 0, 0)]
        async with async_session_factory() as verification:
            count = await verification.scalar(
                select(func.count(TopicSourceAssociation.id)).where(
                    TopicSourceAssociation.enrollment_id == enrollment_id
                )
            )
            rows = list(
                (
                    await verification.execute(
                        select(TopicSourceAssociation)
                        .where(TopicSourceAssociation.enrollment_id == enrollment_id)
                        .order_by(TopicSourceAssociation.topic_id)
                    )
                ).scalars()
            )
            assert count == 2
            assert all(not row.stale and row.status == "proposed" for row in rows)
    finally:
        async with async_session_factory() as cleanup:
            await cleanup.execute(delete(User).where(User.id == user_id))
            await cleanup.execute(delete(CatalogModule).where(CatalogModule.id == catalog_id))
            await cleanup.execute(
                delete(ProviderModuleSnapshot).where(ProviderModuleSnapshot.id == snapshot_id)
            )
            await cleanup.commit()


@pytest.mark.database
async def test_learning_metrics_separate_coverage_recall_and_activity(coverage_records):
    session, user, enrollment, topics, source, _chunks = coverage_records
    proposals = await generate_proposals(enrollment, [source.id], user, session)
    proposed_metrics = await enrollment_learning_metrics(enrollment, session)
    assert proposed_metrics["source_coverage"]["numerator"] == 0
    assert [item["state"] for item in proposed_metrics["source_coverage"]["review_topics"]] == [
        "review",
        "review",
    ]
    association = next(row for row in proposals["associations"] if row.topic_id == topics[0].id)
    await decide_association(enrollment, association.id, "confirm", user, session)

    now = datetime.now(UTC)
    deck = FlashcardDeck(
        id=uuid.uuid4(),
        user_id=user.id,
        title="Approved history",
        generation_scope="enrollment",
        enrollment_id=enrollment.id,
        topic_ids=[topic.id for topic in topics],
        lifecycle="retired",
        approved_at=now - timedelta(days=60),
        retired_at=now,
        approved_snapshot={},
    )
    cards = [
        Flashcard(
            id=uuid.uuid4(),
            deck_id=deck.id,
            user_id=user.id,
            order_index=position,
            card_type="basic",
            question=f"Question {position}",
            answer=f"Answer {position}",
            topic_ids=[topic.id],
            citation_ref="fixture",
            state="active",
            approved=True,
        )
        for position, topic in enumerate(topics)
    ]
    session.add(deck)
    await session.flush()
    session.add_all(cards)
    await session.flush()
    ratings = ["Again", "Hard", "Good", "Easy", "Again", "Good"]
    ease = {"Again": 1, "Hard": 2, "Good": 3, "Easy": 5}
    for index, rating in enumerate(ratings):
        session.add(
            FlashcardAttempt(
                id=uuid.uuid4(),
                user_id=user.id,
                deck_id=deck.id,
                card_id=cards[index % 2].id,
                rating=rating,
                ease=ease[rating],
                idempotency_key=f"metrics-{index}",
                request_hash=str(index) * 64,
                is_correct=rating != "Again",
                created_at=now - timedelta(days=index),
            )
        )
    await session.flush()

    metrics = await enrollment_learning_metrics(enrollment, session, now=now)

    assert metrics["source_coverage"]["numerator"] == 1
    assert metrics["source_coverage"]["percentage"] == 50.0
    assert metrics["recall"]["attempt_count"] == 6
    assert metrics["recall"]["correct_attempts"] == 4
    assert metrics["recall"]["percentage"] == 66.67
    assert [topic["percentage"] for topic in metrics["recall"]["topics"]] == [33.33, 100.0]
    assert metrics["activity"]["attempt_count"] == 6
    assert metrics["activity"]["cards_reviewed"] == 2
    assert metrics["methodology"]["rating_semantics"] == {
        "Again": False,
        "Hard": True,
        "Good": True,
        "Easy": True,
    }


@pytest.mark.database
async def test_provisional_metrics_keep_all_topics_and_activity_is_topic_independent(
    coverage_records,
):
    session, user, enrollment, topics, _source, _chunks = coverage_records
    now = datetime(2026, 7, 20, 12, tzinfo=UTC)
    window_start = now - timedelta(days=30)
    enrollment.topic_state = "provisional"
    topics[1].state = "provisional"
    deck = FlashcardDeck(
        id=uuid.uuid4(),
        user_id=user.id,
        title="Retired approved deck",
        generation_scope="enrollment",
        enrollment_id=enrollment.id,
        topic_ids=[topic.id for topic in topics],
        lifecycle="retired",
        approved_at=now - timedelta(days=60),
        retired_at=now,
        approved_snapshot={},
    )
    cards = [
        Flashcard(
            id=uuid.uuid4(),
            deck_id=deck.id,
            user_id=user.id,
            order_index=index,
            card_type="basic",
            question=f"Question {index}",
            answer=f"Answer {index}",
            topic_ids=topic_ids,
            citation_ref="fixture",
            state="active",
            approved=True,
        )
        for index, topic_ids in enumerate(([topics[0].id], [topics[1].id], [], [uuid.uuid4()]))
    ]
    draft_deck = FlashcardDeck(
        id=uuid.uuid4(),
        user_id=user.id,
        title="Draft deck",
        generation_scope="enrollment",
        enrollment_id=enrollment.id,
        lifecycle="draft",
    )
    draft_card = Flashcard(
        id=uuid.uuid4(),
        deck_id=draft_deck.id,
        user_id=user.id,
        order_index=0,
        card_type="basic",
        question="Draft question",
        answer="Draft answer",
        topic_ids=[topics[0].id],
        citation_ref="fixture",
        state="active",
        approved=True,
    )
    session.add_all([deck, draft_deck])
    await session.flush()
    session.add_all([*cards, draft_card])
    await session.flush()

    attempt_specs = [
        (cards[0], now - timedelta(days=1), "Good"),
        (cards[1], now - timedelta(days=2), "Again"),
        (cards[2], window_start, "Hard"),
        (cards[3], now, "Easy"),
        (cards[0], window_start - timedelta(microseconds=1), "Good"),
        (cards[0], now + timedelta(microseconds=1), "Good"),
        (draft_card, now - timedelta(days=1), "Good"),
    ]
    ease = {"Again": 1, "Hard": 2, "Good": 3, "Easy": 5}
    for index, (card, created_at, rating) in enumerate(attempt_specs):
        session.add(
            FlashcardAttempt(
                id=uuid.uuid4(),
                user_id=user.id,
                deck_id=card.deck_id,
                card_id=card.id,
                rating=rating,
                ease=ease[rating],
                idempotency_key=f"scope-{index}",
                request_hash=str(index) * 64,
                is_correct=rating != "Again",
                created_at=created_at,
            )
        )
    await session.flush()

    metrics = await enrollment_learning_metrics(enrollment, session, now=now)

    coverage = metrics["source_coverage"]
    assert coverage["authoritative"] is False
    assert coverage["denominator"] == 2
    assert coverage["percentage"] is None
    assert coverage["reason_code"] == "provisional_curriculum"
    displayed = coverage["covered_topics"] + coverage["missing_topics"]
    assert {item["topic_id"] for item in displayed} == {topic.id for topic in topics}
    assert [item["topic_id"] for item in metrics["recall"]["topics"]] == [topics[0].id]
    assert metrics["recall"]["attempt_count"] == 1
    assert metrics["recall"]["percentage"] is None
    assert metrics["recall"]["reason_code"] == "provisional_curriculum"
    assert metrics["activity"]["attempt_count"] == 4
    assert metrics["activity"]["cards_reviewed"] == 4

    enrollment.topic_state = "canonical"
    await session.flush()
    mixed = await enrollment_learning_metrics(enrollment, session, now=now)
    assert mixed["source_coverage"]["authoritative"] is False
    assert mixed["source_coverage"]["denominator"] == 2
    assert mixed["recall"]["reason_code"] == "provisional_curriculum"

    topics[0].state = "provisional"
    await session.flush()
    all_provisional = await enrollment_learning_metrics(enrollment, session, now=now)
    assert all_provisional["source_coverage"]["denominator"] == 2
    assert (
        sum(
            len(all_provisional["source_coverage"][key])
            for key in ("covered_topics", "missing_topics", "review_topics", "stale_topics")
        )
        == 2
    )
    assert all_provisional["recall"]["topics"] == []
    assert all_provisional["recall"]["reason_code"] == "provisional_curriculum"
    assert all_provisional["activity"]["attempt_count"] == 4


@pytest.mark.database
async def test_canonical_recall_threshold_no_evidence_and_attempt_lifecycle_boundaries(
    coverage_records,
):
    session, user, enrollment, topics, _source, _chunks = coverage_records
    now = datetime(2026, 7, 20, 12, tzinfo=UTC)
    no_evidence = await enrollment_learning_metrics(enrollment, session, now=now)
    assert no_evidence["recall"]["reason_code"] == "no_attempts"
    assert no_evidence["recall"]["percentage"] is None

    deck = FlashcardDeck(
        id=uuid.uuid4(),
        user_id=user.id,
        title="Boundary deck",
        generation_scope="enrollment",
        enrollment_id=enrollment.id,
        lifecycle="retired",
        approved_at=now - timedelta(days=30),
        retired_at=now,
        approved_snapshot={},
    )
    card = Flashcard(
        id=uuid.uuid4(),
        deck_id=deck.id,
        user_id=user.id,
        order_index=0,
        card_type="basic",
        question="Boundary question",
        answer="Boundary answer",
        topic_ids=[topics[0].id],
        citation_ref="fixture",
        state="active",
        approved=True,
    )
    session.add(deck)
    await session.flush()
    session.add(card)
    await session.flush()
    for index, created_at in enumerate(
        [now - timedelta(days=30), now - timedelta(days=2), now - timedelta(days=1), now, now]
    ):
        session.add(
            FlashcardAttempt(
                id=uuid.uuid4(),
                user_id=user.id,
                deck_id=deck.id,
                card_id=card.id,
                rating="Good",
                ease=3,
                idempotency_key=f"boundary-{index}",
                request_hash=str(index) * 64,
                is_correct=True,
                created_at=created_at,
            )
        )
    session.add(
        FlashcardAttempt(
            id=uuid.uuid4(),
            user_id=user.id,
            deck_id=deck.id,
            card_id=card.id,
            rating="Again",
            ease=1,
            idempotency_key="post-retirement",
            request_hash="f" * 64,
            is_correct=False,
            created_at=now + timedelta(microseconds=1),
        )
    )
    await session.flush()

    metrics = await enrollment_learning_metrics(enrollment, session, now=now)
    assert metrics["recall"]["attempt_count"] == 5
    assert metrics["recall"]["percentage"] == 100.0
    assert metrics["recall"]["reason_code"] is None
    assert metrics["activity"]["attempt_count"] == 5
