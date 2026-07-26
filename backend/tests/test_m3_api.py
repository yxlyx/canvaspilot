import asyncio
import base64
import uuid
from collections.abc import AsyncGenerator
from datetime import UTC, datetime, timedelta
from urllib.parse import parse_qs, urlparse

import jwt
import pytest
import respx
from cryptography.hazmat.primitives.asymmetric import rsa
from httpx import ASGITransport, AsyncClient, Request, Response
from openai import AuthenticationError
from sqlalchemy import delete, func, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.exceptions import WikiBaseError
from app.main import app
from app.models.base import Base
from app.models.flashcard import LearningEvidence
from app.models.m3 import (
    IdempotencyRecord,
    MarkedPaperQuestion,
    ProviderAuthorizationSession,
    ProviderSetting,
    SourceChange,
)
from app.models.source import SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.routers import chat as chat_router
from app.schemas.sources import SourceCreate
from app.services import idempotency as idempotency_service
from app.services import llm as llm_service
from app.services import meters as meter_service
from app.services import provider_auth as provider_auth_service
from app.services import providers as provider_service
from app.services.idempotency import execute_idempotent
from app.services.retrieval import RetrievedChunk
from app.services.sources import create_or_update_source


async def _add_idempotency_key(request) -> None:
    if (
        request.method in {"POST", "PUT", "PATCH", "DELETE"}
        and "Idempotency-Key" not in request.headers
    ):
        request.headers["Idempotency-Key"] = str(uuid.uuid4())


def _oauth_identity(
    nonce: str,
    audience: str,
    *,
    issuer: str = "https://auth.openai.com",
    account_id: str = "acct-123",
    subject_id: str = "openai-user-123",
) -> tuple[str, dict]:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_numbers = private_key.public_key().public_numbers()
    key_id = f"test-signing-key-{uuid.uuid4()}"
    now = datetime.now(UTC)
    token = jwt.encode(
        {
            "iss": issuer,
            "aud": audience,
            "iat": now,
            "exp": now + timedelta(minutes=10),
            "nonce": nonce,
            "sub": subject_id,
            "email": "student@example.com",
            "https://api.openai.com/auth": {"chatgpt_account_id": account_id},
        },
        private_key,
        algorithm="RS256",
        headers={"kid": key_id},
    )
    jwks = {
        "keys": [
            {
                "kty": "RSA",
                "kid": key_id,
                "use": "sig",
                "alg": "RS256",
                "n": base64.urlsafe_b64encode(
                    public_numbers.n.to_bytes((public_numbers.n.bit_length() + 7) // 8, "big")
                )
                .rstrip(b"=")
                .decode(),
                "e": base64.urlsafe_b64encode(
                    public_numbers.e.to_bytes((public_numbers.e.bit_length() + 7) // 8, "big")
                )
                .rstrip(b"=")
                .decode(),
            }
        ]
    }
    return token, jwks


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def m3_client() -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User, User, dict], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        emails = ["m3-owner@example.com", "m3-other@example.com"]
        await session.execute(delete(User).where(User.email.in_(emails)))
        owner = User(id=uuid.uuid4(), name="M3 Owner", email=emails[0])
        other = User(id=uuid.uuid4(), name="M3 Other", email=emails[1])
        user_ids = [owner.id, other.id]
        session.add_all([owner, other])
        await session.commit()
        principal = {"user": owner}

        async def override_user():
            user = principal["user"]
            await session.refresh(user)
            return user

        async def override_db():
            yield session

        app.dependency_overrides[get_current_user] = override_user
        app.dependency_overrides[get_db] = override_db
        transport = ASGITransport(app=app)
        try:
            async with AsyncClient(
                transport=transport,
                base_url="http://test",
                event_hooks={"request": [_add_idempotency_key]},
            ) as client:
                yield client, session, owner, other, principal
        finally:
            app.dependency_overrides.clear()
            await session.rollback()
            await session.execute(delete(User).where(User.id.in_(user_ids)))
            await session.commit()
    await engine.dispose()


@pytest.fixture
async def authenticated_m3_clients():
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
    suffix = uuid.uuid4().hex
    owner_email = f"m3-real-owner-{suffix}@example.com"
    other_email = f"m3-real-other-{suffix}@example.com"
    password = "IntegrationPassword1"
    transport = ASGITransport(app=app)
    async with (
        AsyncClient(
            transport=transport,
            base_url="http://test",
            event_hooks={"request": [_add_idempotency_key]},
        ) as owner_client,
        AsyncClient(
            transport=transport,
            base_url="http://test",
            event_hooks={"request": [_add_idempotency_key]},
        ) as other_client,
        AsyncClient(
            transport=transport,
            base_url="http://test",
            event_hooks={"request": [_add_idempotency_key]},
        ) as parallel_owner_client,
    ):
        owner_registration = await owner_client.post(
            "/api/auth/register",
            json={"name": "Real Owner", "email": owner_email, "password": password},
        )
        other_registration = await other_client.post(
            "/api/auth/register",
            json={"name": "Real Other", "email": other_email, "password": password},
        )
        assert owner_registration.status_code == other_registration.status_code == 201
        owner_id = owner_registration.json()["user"]["id"]
        other_id = other_registration.json()["user"]["id"]
        assert (await owner_client.post("/api/auth/logout")).status_code == 200
        assert (
            await owner_client.post(
                "/api/auth/login", json={"email": owner_email, "password": password}
            )
        ).status_code == 200
        assert (
            await parallel_owner_client.post(
                "/api/auth/login", json={"email": owner_email, "password": password}
            )
        ).status_code == 200
        assert (await owner_client.get("/api/auth/me")).json()["id"] == owner_id
        assert (await other_client.get("/api/auth/me")).json()["id"] == other_id
        yield owner_client, other_client, parallel_owner_client
    async with async_session_factory() as session:
        await session.execute(delete(User).where(User.email.in_([owner_email, other_email])))
        await session.commit()
    await engine.dispose()


@pytest.mark.asyncio
async def test_real_sessions_isolate_users_and_serialize_duplicate_writes(
    authenticated_m3_clients,
):
    owner_client, other_client, parallel_owner_client = authenticated_m3_clients
    uploaded = await owner_client.post(
        "/api/marked-papers",
        json={
            "filename": "private.pdf",
            "content_type": "application/pdf",
            "content_base64": base64.b64encode(b"private").decode(),
        },
    )
    assert uploaded.status_code == 201
    paper_id = uploaded.json()["id"]
    assert (await other_client.get(f"/api/marked-papers/{paper_id}")).status_code == 404
    foreign_create = await other_client.post(
        f"/api/marked-papers/{paper_id}/questions",
        json={"question_number": 1, "question_text": "Not mine"},
    )
    assert foreign_create.status_code == 404

    duplicate_results = await asyncio.gather(
        owner_client.post(
            f"/api/marked-papers/{paper_id}/questions",
            json={"question_number": 1, "question_text": "First"},
        ),
        parallel_owner_client.post(
            f"/api/marked-papers/{paper_id}/questions",
            json={"question_number": 1, "question_text": "Racing duplicate"},
        ),
    )
    assert sorted(response.status_code for response in duplicate_results) == [201, 422]
    created_question = (await owner_client.get(f"/api/marked-papers/{paper_id}")).json()[
        "questions"
    ][0]
    update_results = await asyncio.gather(
        owner_client.patch(
            f"/api/marked-papers/{paper_id}/questions/{created_question['id']}",
            json={
                "awarded_marks": 1,
                "available_marks": 2,
                "topic_tag": "Integration",
                "reviewed": True,
            },
        ),
        parallel_owner_client.patch(
            f"/api/marked-papers/{paper_id}/questions/{created_question['id']}",
            json={
                "awarded_marks": 2,
                "available_marks": 2,
                "topic_tag": " integration ",
                "reviewed": True,
            },
        ),
    )
    assert [response.status_code for response in update_results] == [200, 200]
    async with async_session_factory() as session:
        evidence_count = await session.scalar(
            select(func.count(LearningEvidence.id)).where(
                LearningEvidence.marked_paper_question_id == uuid.UUID(created_question["id"])
            )
        )
    assert evidence_count == 1
    updated_question = (await owner_client.get(f"/api/marked-papers/{paper_id}")).json()[
        "questions"
    ][0]
    assert updated_question["topic_tag"] == "integration"

    provider_results = await asyncio.gather(
        owner_client.put(
            "/api/providers/settings",
            json={"provider": "openai", "api_key": "first-key", "model": "gpt-4o-mini"},
        ),
        parallel_owner_client.put(
            "/api/providers/settings",
            json={"provider": "openai", "api_key": "second-key", "model": "gpt-4o"},
        ),
    )
    assert [response.status_code for response in provider_results] == [200, 200]
    settings = (await owner_client.get("/api/providers/settings")).json()
    assert len(settings) == 1
    assert (await other_client.get("/api/providers/settings")).json() == []


@pytest.mark.asyncio
async def test_provider_test_serializes_configuration_and_disconnect(
    authenticated_m3_clients,
):
    owner_client, _, parallel_owner_client = authenticated_m3_clients
    configured = await owner_client.put(
        "/api/providers/settings",
        json={"provider": "openai", "api_key": "initial-key", "model": "gpt-4o-mini"},
    )
    assert configured.status_code == 200

    probe_started = asyncio.Event()
    release_probe = asyncio.Event()

    async def slow_probe(_request):
        probe_started.set()
        await release_probe.wait()
        return Response(200, json={"data": [{"id": "gpt-4o-mini"}]})

    with respx.mock:
        respx.get("https://api.openai.com/v1/models").mock(side_effect=slow_probe)
        test_task = asyncio.create_task(owner_client.post("/api/providers/openai/test"))
        await probe_started.wait()
        configure_task = asyncio.create_task(
            parallel_owner_client.put(
                "/api/providers/settings",
                json={"provider": "openai", "api_key": "replacement-key", "model": "gpt-4o"},
            )
        )
        await asyncio.sleep(0.05)
        assert not configure_task.done()
        release_probe.set()
        tested, reconfigured = await asyncio.gather(test_task, configure_task)
    assert tested.status_code == reconfigured.status_code == 200
    current = (await owner_client.get("/api/providers/settings")).json()[0]
    assert current["model"] == "gpt-4o"
    assert current["status"] == "configured"

    probe_started = asyncio.Event()
    release_probe = asyncio.Event()

    async def slow_replacement_probe(_request):
        probe_started.set()
        await release_probe.wait()
        return Response(200, json={"data": [{"id": "gpt-4o"}]})

    with respx.mock:
        respx.get("https://api.openai.com/v1/models").mock(side_effect=slow_replacement_probe)
        test_task = asyncio.create_task(owner_client.post("/api/providers/openai/test"))
        await probe_started.wait()
        disconnect_task = asyncio.create_task(parallel_owner_client.delete("/api/providers/openai"))
        await asyncio.sleep(0.05)
        assert not disconnect_task.done()
        release_probe.set()
        tested, disconnected = await asyncio.gather(test_task, disconnect_task)
    assert tested.status_code == 200
    assert disconnected.status_code == 204
    assert (await owner_client.get("/api/providers/settings")).json() == []


@pytest.mark.asyncio
async def test_idempotency_is_durable_replays_and_conflicts_transactionally(
    authenticated_m3_clients,
):
    owner_client, _, parallel_owner_client = authenticated_m3_clients
    key = str(uuid.uuid4())
    payload = {
        "filename": "idempotent.txt",
        "content_type": "text/plain",
        "content_base64": base64.b64encode(b"Q1: Durable request").decode(),
    }
    first, concurrent = await asyncio.gather(
        owner_client.post("/api/marked-papers", json=payload, headers={"Idempotency-Key": key}),
        parallel_owner_client.post(
            "/api/marked-papers", json=payload, headers={"Idempotency-Key": key}
        ),
    )
    assert first.status_code == concurrent.status_code == 201
    assert first.json() == concurrent.json()

    replay = await owner_client.post(
        "/api/marked-papers", json=payload, headers={"Idempotency-Key": key}
    )
    assert replay.status_code == 201
    assert replay.json() == first.json()
    async with async_session_factory() as session:
        stored = await session.scalar(
            select(IdempotencyRecord).where(IdempotencyRecord.idempotency_key == key)
        )
        assert stored.response_body == first.json()
        assert set(stored.response_body) == {"id"}

    conflict = await owner_client.post(
        "/api/marked-papers",
        json={**payload, "filename": "different.txt"},
        headers={"Idempotency-Key": key},
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"] == "idempotency_key_reused"


@pytest.mark.asyncio
async def test_idempotency_locks_same_key_without_serializing_different_keys(
    m3_client, monkeypatch
):
    _, _, owner, _, _ = m3_client
    monkeypatch.setattr(idempotency_service, "MAX_IDEMPOTENCY_RECORDS_PER_USER", 1)

    async def run(key, execute):
        async with async_session_factory() as concurrent_session:
            return await execute_idempotent(
                db=concurrent_session,
                user=owner,
                key=key,
                operation="test.concurrent",
                payload={"value": 1},
                status_code=200,
                response_type=dict,
                execute=execute,
            )

    different_started = 0
    both_different_started = asyncio.Event()
    release_different = asyncio.Event()

    async def execute_different():
        nonlocal different_started
        different_started += 1
        if different_started == 2:
            both_different_started.set()
        await release_different.wait()
        return {"ok": True}

    different_tasks = [
        asyncio.create_task(run(str(uuid.uuid4()), execute_different)) for _ in range(2)
    ]
    try:
        await asyncio.wait_for(both_different_started.wait(), timeout=5)
    finally:
        release_different.set()
        different_responses = await asyncio.gather(*different_tasks)
    assert [response.status_code for response in different_responses] == [200, 200]
    async with async_session_factory() as count_session:
        concurrent_count = await count_session.scalar(
            select(func.count(IdempotencyRecord.id)).where(IdempotencyRecord.user_id == owner.id)
        )
    assert concurrent_count == 2  # At most one overshoot for two in-flight keys.

    same_key = str(uuid.uuid4())
    same_started = asyncio.Event()
    release_same = asyncio.Event()
    same_executions = 0

    async def execute_same():
        nonlocal same_executions
        same_executions += 1
        same_started.set()
        await release_same.wait()
        return {"ok": True}

    first = asyncio.create_task(run(same_key, execute_same))
    await asyncio.wait_for(same_started.wait(), timeout=5)
    second = asyncio.create_task(run(same_key, execute_same))
    await asyncio.sleep(0.1)
    assert not second.done()
    assert same_executions == 1
    release_same.set()
    first_response, second_response = await asyncio.gather(first, second)
    assert first_response.status_code == second_response.status_code == 200
    assert same_executions == 1
    async with async_session_factory() as count_session:
        eventual_count = await count_session.scalar(
            select(func.count(IdempotencyRecord.id)).where(IdempotencyRecord.user_id == owner.id)
        )
    assert eventual_count == 1


@pytest.mark.asyncio
async def test_transient_failure_does_not_complete_idempotency_record(m3_client):
    _, session, owner, _, _ = m3_client
    owner_id = owner.id
    key = str(uuid.uuid4())

    async def fail():
        raise RuntimeError("transient upstream failure")

    with pytest.raises(RuntimeError):
        await execute_idempotent(
            db=session,
            user=owner,
            key=key,
            operation="test.create",
            payload={"value": 1},
            status_code=201,
            response_type=dict,
            execute=fail,
        )
    await session.refresh(owner)
    assert (
        await session.scalar(
            select(func.count(IdempotencyRecord.id)).where(
                IdempotencyRecord.user_id == owner_id,
                IdempotencyRecord.idempotency_key == key,
            )
        )
        == 0
    )
    await session.refresh(owner)

    async def succeed():
        return {"created": True}

    response = await execute_idempotent(
        db=session,
        user=owner,
        key=key,
        operation="test.create",
        payload={"value": 1},
        status_code=201,
        response_type=dict,
        execute=succeed,
    )
    assert response.status_code == 201


@pytest.mark.asyncio
async def test_idempotency_ttl_cleanup_is_bounded_and_user_cap_is_enforced(m3_client, monkeypatch):
    _, session, owner, _, _ = m3_client
    now = datetime.now(UTC)
    for index in range(6):
        session.add(
            IdempotencyRecord(
                user_id=owner.id,
                idempotency_key=f"seed-key-{index:016d}",
                operation="seed",
                request_hash="0" * 64,
                response_status=200,
                response_body={"ok": True},
                created_at=now - timedelta(hours=6 - index),
                expires_at=now - timedelta(hours=1) if index < 3 else now + timedelta(hours=1),
            )
        )
    await session.commit()
    monkeypatch.setattr(idempotency_service, "MAX_IDEMPOTENCY_RECORDS_PER_USER", 3)
    monkeypatch.setattr(idempotency_service, "CLEANUP_BATCH_SIZE", 2)

    async def succeed():
        return {"ok": True}

    response = await execute_idempotent(
        db=session,
        user=owner,
        key=str(uuid.uuid4()),
        operation="test.cleanup",
        payload=None,
        status_code=200,
        response_type=dict,
        execute=succeed,
    )
    assert response.status_code == 200
    records = list(
        (
            await session.execute(
                select(IdempotencyRecord).where(IdempotencyRecord.user_id == owner.id)
            )
        ).scalars()
    )
    assert len(records) <= 3
    assert sum(record.expires_at <= now for record in records) <= 1


@pytest.mark.asyncio
async def test_marked_paper_pagination_preserves_default_collection_and_stable_pages(m3_client):
    client, session, owner, _, _ = m3_client
    for index in range(3):
        response = await client.post(
            "/api/marked-papers",
            json={
                "filename": f"page-{index}.pdf",
                "content_type": "application/pdf",
                "content_base64": base64.b64encode(str(index).encode()).decode(),
            },
        )
        assert response.status_code == 201
    await session.execute(
        text("UPDATE marked_papers SET created_at = now() WHERE user_id = :user_id"),
        {"user_id": owner.id},
    )
    await session.commit()

    default_page = (await client.get("/api/marked-papers")).json()
    first_page = (await client.get("/api/marked-papers/page?limit=2")).json()
    inserted = await client.post(
        "/api/marked-papers",
        json={
            "filename": "inserted.pdf",
            "content_type": "application/pdf",
            "content_base64": base64.b64encode(b"inserted").decode(),
        },
    )
    second_page = (
        await client.get("/api/marked-papers/page?limit=2&cursor=" + first_page["next_cursor"])
    ).json()
    traversed_ids = [paper["id"] for paper in first_page["items"] + second_page["items"]]
    assert traversed_ids == [paper["id"] for paper in default_page]
    assert len(traversed_ids) == len(set(traversed_ids))
    fresh_ids = [
        paper["id"]
        for paper in (await client.get("/api/marked-papers/page?limit=100")).json()["items"]
    ]
    assert inserted.json()["id"] in fresh_ids
    assert (await client.get("/api/marked-papers?limit=1&offset=10001")).status_code == 200


@pytest.mark.asyncio
async def test_m3_migration_tables_and_durable_audit_columns_exist(m3_client):
    _, session, _, _, _ = m3_client
    table_names = {
        "idempotency_records",
        "study_outputs",
        "study_output_citations",
        "wiki_revisions",
        "source_changes",
        "health_findings",
        "marked_papers",
        "marked_paper_questions",
        "provider_settings",
    }
    database_columns: dict[str, set[str]] = {name: set() for name in table_names}
    rows = await session.execute(
        text(
            "SELECT table_name, column_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND table_name = ANY(:table_names)"
        ),
        {"table_names": list(table_names)},
    )
    for table_name, column_name in rows:
        database_columns[table_name].add(column_name)
    for table_name in table_names:
        assert database_columns[table_name] == set(Base.metadata.tables[table_name].columns.keys())

    constraints = {
        row[0]: row[1]
        for row in await session.execute(
            text(
                "SELECT conname, confdeltype::text FROM pg_constraint "
                "WHERE conname IN ('ck_marked_question_marks', "
                "'fk_learning_evidence_marked_question')"
            )
        )
    }
    assert constraints == {
        "ck_marked_question_marks": " ",
        "fk_learning_evidence_marked_question": "c",
    }
    indexes = {
        row[0]
        for row in await session.execute(
            text(
                "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' "
                "AND indexname IN ('uq_marked_questions_paper_number', "
                "'uq_learning_evidence_marked_question', "
                "'uq_provider_settings_user_provider', "
                "'uq_idempotency_records_user_key', "
                "'ix_idempotency_records_created_at', "
                "'ix_idempotency_records_expires_at')"
            )
        )
    }
    assert indexes == {
        "uq_marked_questions_paper_number",
        "uq_learning_evidence_marked_question",
        "uq_provider_settings_user_provider",
        "uq_idempotency_records_user_key",
        "ix_idempotency_records_created_at",
        "ix_idempotency_records_expires_at",
    }


@pytest.mark.asyncio
async def test_external_source_upsert_updates_and_tracks_mutable_metadata(m3_client):
    _, session, owner, _, _ = m3_client
    external_id = uuid.uuid4().hex
    source = await create_or_update_source(
        owner,
        SourceCreate(
            source_type="markdown",
            origin="test",
            external_id=external_id,
            title="Old title",
            citation_label="Old citation",
            topic_tags=["old"],
            course_context="Old course",
            project_context="Old project",
        ),
        session,
    )

    updated = await create_or_update_source(
        owner,
        SourceCreate(
            source_type="plain_text",
            origin="test",
            external_id=external_id,
            title="New title",
            citation_label="New citation",
            topic_tags=["New Topic"],
            course_context="New course",
            project_context="New project",
            import_error="New error",
        ),
        session,
    )

    assert updated.id == source.id
    assert updated.source_type.value == "plain_text"
    assert updated.citation_label == "New citation"
    assert updated.topic_tags == ["new topic"]
    assert updated.course_context == "New course"
    assert updated.project_context == "New project"
    change = (
        await session.execute(
            select(SourceChange).where(
                SourceChange.source_id == source.id,
                SourceChange.change_type == "source_updated",
            )
        )
    ).scalar_one()
    assert change.before_snapshot["source_type"] == "markdown"
    assert change.after_snapshot["source_type"] == "plain_text"
    assert change.after_snapshot["citation_label"] == "New citation"
    assert change.after_snapshot["topic_tags"] == ["new topic"]
    assert change.after_snapshot["course_context"] == "New course"
    assert change.after_snapshot["project_context"] == "New project"


async def _ready_source(session: AsyncSession, user: User, title: str, url: str):
    source = await create_or_update_source(
        user,
        SourceCreate(
            source_type="markdown",
            origin="test",
            external_id=str(uuid.uuid4()),
            title=title,
            source_url=url,
            topic_tags=["integration"],
        ),
        session,
    )
    source.status = SourceStatus.READY
    for index in range(4):
        session.add(
            SourceChunk(
                source_id=source.id,
                chunk_index=index,
                citation_ref=f"{title}#{index + 1}",
                location_label=f"Section {index + 1}",
                content=(
                    f"{title} evidence section {index + 1} contains enough grounded detail "
                    "for deterministic integration testing."
                ),
                token_count=16,
            )
        )
    await session.commit()
    await session.refresh(source, attribute_names=["chunks"])
    return source


@pytest.mark.asyncio
async def test_workspace_health_empty_healthy_and_issue_states(m3_client):
    client, session, owner, _, _ = m3_client

    assert (await client.post("/api/workspace/health")).status_code == 200
    empty_findings = (await client.get("/api/workspace/health")).json()
    assert len(empty_findings) == 1
    assert empty_findings[0]["code"] == "workspace_not_evaluated"
    assert empty_findings[0]["severity"] == "info"
    assert empty_findings[0]["state"] == "unknown"
    assert empty_findings[0]["resource_type"] == "workspace"
    assert "finish indexing a source" in empty_findings[0]["recommendation"]
    assert all(finding["code"] != "workspace_healthy" for finding in empty_findings)

    source = await create_or_update_source(
        owner,
        SourceCreate(
            source_type="markdown",
            origin="health-test",
            external_id=str(uuid.uuid4()),
            title="Healthy source",
            source_url="https://example.test/healthy",
            topic_tags=[],
        ),
        session,
    )
    await session.commit()

    assert (await client.post("/api/workspace/health")).status_code == 200
    pending_findings = (await client.get("/api/workspace/health")).json()
    assert [(finding["code"], finding["state"]) for finding in pending_findings] == [
        ("workspace_not_evaluated", "unknown")
    ]

    source.status = SourceStatus.INDEXING
    await session.commit()
    assert (await client.post("/api/workspace/health")).status_code == 200
    indexing_findings = (await client.get("/api/workspace/health")).json()
    assert [(finding["code"], finding["state"]) for finding in indexing_findings] == [
        ("workspace_not_evaluated", "unknown")
    ]

    source.status = SourceStatus.ARCHIVED
    await session.commit()
    assert (await client.post("/api/workspace/health")).status_code == 200
    archived_findings = (await client.get("/api/workspace/health")).json()
    assert [(finding["code"], finding["state"]) for finding in archived_findings] == [
        ("workspace_not_evaluated", "unknown")
    ]

    source.status = SourceStatus.READY
    await session.commit()
    assert (await client.post("/api/workspace/health")).status_code == 200
    healthy_findings = (await client.get("/api/workspace/health")).json()
    assert len(healthy_findings) == 1
    assert healthy_findings[0]["code"] == "workspace_healthy"
    assert healthy_findings[0]["severity"] == "info"
    assert healthy_findings[0]["state"] == "healthy"

    source.status = SourceStatus.FAILED
    await session.commit()

    assert (await client.post("/api/workspace/health")).status_code == 200
    issue_findings = (await client.get("/api/workspace/health")).json()
    assert len(issue_findings) == 1
    assert issue_findings[0]["code"] == "unsupported_or_failed_source"
    assert issue_findings[0]["severity"] == "error"
    assert issue_findings[0]["state"] == "failed"
    assert all(finding["code"] != "workspace_healthy" for finding in issue_findings)

    first_notifications = (await client.get("/api/notifications")).json()["items"]
    first_health_notifications = [
        item for item in first_notifications if item["kind"] == "health_attention"
    ]
    assert len(first_health_notifications) == 1
    first_notification = first_health_notifications[0]

    assert (await client.post("/api/workspace/health")).status_code == 200
    refreshed_findings = (await client.get("/api/workspace/health")).json()
    assert len(refreshed_findings) == 1
    assert refreshed_findings[0]["id"] != issue_findings[0]["id"]
    refreshed_notifications = (await client.get("/api/notifications")).json()["items"]
    refreshed_health_notifications = [
        item for item in refreshed_notifications if item["kind"] == "health_attention"
    ]
    assert len(refreshed_health_notifications) == 1
    assert refreshed_health_notifications[0]["id"] == first_notification["id"]
    assert refreshed_health_notifications[0]["href"] == (
        f"/sources/health/{refreshed_findings[0]['id']}"
    )


@pytest.mark.asyncio
async def test_m3_grounded_output_wiki_history_health_export_and_two_user_isolation(m3_client):
    client, session, owner, other, principal = m3_client
    first = await _ready_source(session, owner, "Alpha", "https://example.test/shared")
    second = await _ready_source(session, owner, "Beta", "https://example.test/beta")
    await _ready_source(session, owner, "Renamed Alpha", "https://example.test/shared#fragment")
    first.chunks[0].content = (
        "Overview. This cited chunk contains substantial owner-scoped evidence after its "
        "intentionally short first sentence."
    )
    await session.commit()

    compile_response = await client.post(
        "/api/wiki/compile", json={"source_ids": [str(first.id), str(second.id)]}
    )
    assert compile_response.status_code == 200
    pages = compile_response.json()["pages"]
    source_page = next(page for page in pages if page["title"] == "Alpha")

    generated = await client.post(
        "/api/outputs",
        json={
            "output_type": "study_guide",
            "source_ids": [str(first.id), str(second.id)],
        },
    )
    assert generated.status_code == 201
    output = generated.json()
    assert output["status"] == "grounded"
    assert "## Review point" in output["content"]
    assert "truncated" in output["message"]
    assert {citation["source_id"] for citation in output["citations"]} == {
        str(first.id),
        str(second.id),
    }
    assert (await client.get("/api/outputs")).status_code == 200
    assert (await client.get("/api/outputs?limit=21&offset=10001")).status_code == 200
    assert (await client.get(f"/api/outputs/{output['id']}")).status_code == 200
    page_generated = await client.post(
        "/api/outputs",
        json={"output_type": "summary", "wiki_page_id": source_page["id"]},
    )
    assert page_generated.status_code == 201
    page_output = page_generated.json()
    assert page_output["status"] == "grounded"
    page_content = page_output["content"]
    assert page_content.splitlines()[0] == "Overview. [1]"
    assert "intentionally short first sentence" not in page_content
    assert "Alpha evidence section 4" in page_content
    assert len(page_output["citations"]) == 4
    output_first_page = (await client.get("/api/outputs/page?limit=1")).json()
    inserted_output = await client.post(
        "/api/outputs", json={"output_type": "outline", "source_ids": [str(first.id)]}
    )
    output_second_page = (
        await client.get("/api/outputs/page?limit=100&cursor=" + output_first_page["next_cursor"])
    ).json()
    traversed_output_ids = [
        item["id"] for item in output_first_page["items"] + output_second_page["items"]
    ]
    assert traversed_output_ids == [page_generated.json()["id"], output["id"]]
    assert inserted_output.json()["id"] not in traversed_output_ids
    assert inserted_output.json()["id"] in [
        item["id"] for item in (await client.get("/api/outputs/page?limit=100")).json()["items"]
    ]
    filtered_outputs = (
        await client.get(
            "/api/outputs/page",
            params={"limit": 1, "output_type": "study_guide"},
        )
    ).json()
    assert [item["id"] for item in filtered_outputs["items"]] == [output["id"]]
    assert filtered_outputs["next_cursor"] is None
    assert (
        await client.get("/api/outputs/page", params={"output_type": "unsupported"})
    ).status_code == 422

    activity_response = await client.get("/api/wiki/activity")
    assert activity_response.status_code == 200
    output_activity_types = {
        entry["event_type"]
        for entry in activity_response.json()
        if entry["category"] == "study_guides"
    }
    assert output_activity_types == {"summary", "outline", "study_guide"}

    page_download = await client.get(f"/api/wiki/pages/{source_page['slug']}/download")
    assert page_download.status_code == 200
    assert page_download.headers["x-content-type-options"] == "nosniff"
    archive = await client.post("/api/wiki/download", json={"page_ids": [source_page["id"]]})
    assert archive.status_code == 200
    revisions = await client.get(f"/api/wiki/pages/{source_page['id']}/revisions")
    assert revisions.status_code == 200
    revision_number = revisions.json()[0]["revision_number"]
    diff = await client.get(
        f"/api/wiki/pages/{source_page['id']}/diff",
        params={"from_revision": revision_number, "to_revision": revision_number},
    )
    assert diff.status_code == 200

    first_health = await client.post("/api/workspace/health")
    second_health = await client.post("/api/workspace/health")
    listed_health = await client.get("/api/workspace/health")
    assert first_health.status_code == second_health.status_code == listed_health.status_code == 200
    assert first_health.json() == second_health.json() == {"ok": True}
    assert "duplicate_source" in {finding["code"] for finding in listed_health.json()}
    finding_id = listed_health.json()[0]["id"]
    assert (await client.get(f"/api/workspace/health/{finding_id}")).status_code == 200
    assert (await client.get("/api/workspace/history")).status_code == 200
    assert (await client.get("/api/workspace/source-changes")).status_code == 200
    meters = await client.get("/api/meters/topics")
    assert meters.status_code == 200

    first.status = SourceStatus.ARCHIVED
    first.topic_tags = ["integration", "archived-only"]
    await session.commit()
    resolved_health = await client.post("/api/workspace/health")
    assert resolved_health.json() == {"ok": True}
    resolved_findings = (await client.get("/api/workspace/health")).json()
    assert "duplicate_source" not in {finding["code"] for finding in resolved_findings}
    assert "archived-only" not in {finding["topic"] for finding in resolved_findings}
    assert (await client.post("/api/wiki/compile")).status_code == 200
    unavailable_download = await client.get(f"/api/wiki/pages/{source_page['slug']}/download")
    assert unavailable_download.status_code == 404
    preserved = await client.get(f"/api/wiki/pages/{source_page['id']}/revisions")
    assert preserved.status_code == 200
    assert preserved.json()

    principal["user"] = other
    assert (await client.get(f"/api/outputs/{output['id']}")).status_code == 404
    unavailable_download = await client.get(f"/api/wiki/pages/{source_page['slug']}/download")
    assert unavailable_download.status_code == 404
    foreign_revisions = await client.get(f"/api/wiki/pages/{source_page['id']}/revisions")
    assert foreign_revisions.status_code == 404
    assert (await client.get(f"/api/workspace/health/{finding_id}")).status_code == 404
    foreign_diff = await client.get(
        f"/api/wiki/pages/{source_page['id']}/diff",
        params={"from_revision": revision_number, "to_revision": revision_number},
    )
    assert foreign_diff.status_code == 404
    foreign_generation = await client.post(
        "/api/outputs", json={"output_type": "summary", "source_ids": [str(first.id)]}
    )
    assert foreign_generation.status_code == 404
    foreign_export = await client.post("/api/wiki/download", json={"page_ids": [source_page["id"]]})
    assert foreign_export.status_code == 404
    assert (await client.get("/api/outputs")).json() == []
    assert (await client.get("/api/workspace/history")).json() == []
    assert (await client.get("/api/workspace/source-changes")).json() == []
    assert (await client.get("/api/workspace/health")).json() == []
    assert (await client.get("/api/meters/topics")).json() == []


@pytest.mark.asyncio
async def test_marked_paper_manual_lifecycle_validation_meter_and_isolation(m3_client, monkeypatch):
    client, session, owner, other, principal = m3_client
    duplicate_upload = await client.post(
        "/api/marked-papers",
        json={
            "filename": "duplicate.txt",
            "content_type": "text/plain",
            "content_base64": base64.b64encode(
                b"Q1: First\nMarks: 1/1\n\nQ1: Duplicate\nMarks: 1/1"
            ).decode(),
        },
    )
    assert duplicate_upload.status_code == 422
    invalid_marks = await client.post(
        "/api/marked-papers",
        json={
            "filename": "invalid-marks.txt",
            "content_type": "text/plain",
            "content_base64": base64.b64encode(b"Q1: Impossible\nMarks: 9/1").decode(),
        },
    )
    assert invalid_marks.status_code == 422
    incomplete_upload = await client.post(
        "/api/marked-papers",
        json={
            "filename": "incomplete.txt",
            "content_type": "text/plain",
            "content_base64": base64.b64encode(
                b"Q1: Explain photosynthesis\nTopic: Biology\nFeedback: Add detail"
            ).decode(),
        },
    )
    assert incomplete_upload.status_code == 201
    incomplete_paper = (
        await client.get(f"/api/marked-papers/{incomplete_upload.json()['id']}")
    ).json()
    assert incomplete_paper["extraction_status"] == "pending_review"
    incomplete_question = incomplete_paper["questions"][0]
    assert incomplete_question["reviewed"] is False
    assert incomplete_question["awarded_marks"] is None
    assert incomplete_question["available_marks"] is None
    bounded_upload = await client.post(
        "/api/marked-papers",
        json={
            "filename": "bounded.txt",
            "content_type": "text/plain",
            "content_base64": base64.b64encode(
                "\n\n".join(
                    f"Q{number}: Extracted\nMarks: 1/1" for number in range(1, 201)
                ).encode()
            ).decode(),
        },
    )
    assert bounded_upload.status_code == 201
    assert set(bounded_upload.json()) == {"id"}
    assert len(bounded_upload.content) < 1024
    quota = await client.post(
        f"/api/marked-papers/{bounded_upload.json()['id']}/questions",
        json={"question_number": 201, "question_text": "Over quota"},
    )
    assert quota.status_code == 413
    uploaded = await client.post(
        "/api/marked-papers",
        json={
            "filename": "scan.pdf",
            "content_type": "application/pdf",
            "content_base64": base64.b64encode(b"not retained as evidence").decode(),
        },
    )
    assert uploaded.status_code == 201
    paper = (await client.get(f"/api/marked-papers/{uploaded.json()['id']}")).json()
    assert paper["extraction_status"] == "unsupported"
    assert paper["questions"] == []

    created = await client.post(
        f"/api/marked-papers/{paper['id']}/questions",
        json={
            "question_number": 1,
            "question_text": "Manually transcribed question",
            "awarded_marks": 3,
            "available_marks": 5,
            "topic_tag": "integration",
            "confidence": 0.8,
            "reviewed": True,
        },
    )
    assert created.status_code == 201
    question = (await client.get(f"/api/marked-papers/{paper['id']}")).json()["questions"][0]
    assert question["reviewed_at"] is not None
    stored_question = await session.get(MarkedPaperQuestion, uuid.UUID(question["id"]))
    stored_question.reviewed_at = datetime.now(UTC) - timedelta(days=45)
    await session.commit()
    legacy_meter = (await client.get("/api/meters/topics")).json()[0]
    assert legacy_meter["stale"] is True
    assert legacy_meter["estimated_completion"] is None
    assert legacy_meter["evidence_confidence"] is None
    assert legacy_meter["reason_code"] == "legacy_meter_non_authoritative"
    assert [signal["name"] for signal in legacy_meter["signals"]] == [
        "source_count",
        "flashcard_recall",
        "marked_paper_score",
        "self_reported_confidence",
    ]
    refreshed = await client.patch(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}",
        json={"feedback": "Freshly reviewed"},
    )
    assert refreshed.status_code == 200
    replay_key = str(uuid.uuid4())
    replay_payload = {"feedback": "Exactly once review"}
    first_review = await client.patch(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}",
        json=replay_payload,
        headers={"Idempotency-Key": replay_key},
    )
    replayed_review = await client.patch(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}",
        json=replay_payload,
        headers={"Idempotency-Key": replay_key},
    )
    assert first_review.json() == replayed_review.json()
    changed_review = await client.patch(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}",
        json={"feedback": "Changed"},
        headers={"Idempotency-Key": replay_key},
    )
    assert changed_review.status_code == 409
    assert (await client.get("/api/meters/topics")).json()[0]["stale"] is False
    duplicate = await client.post(
        f"/api/marked-papers/{paper['id']}/questions",
        json={"question_number": 1, "question_text": "Duplicate"},
    )
    assert duplicate.status_code == 422
    nullable = await client.patch(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}",
        json={"question_text": None},
    )
    assert nullable.status_code == 422
    meter = (await client.get("/api/meters/topics")).json()[0]
    confidence = next(
        signal for signal in meter["signals"] if signal["name"] == "self_reported_confidence"
    )
    assert confidence["value"] == pytest.approx(0.8)

    stored_question.reviewed_at = datetime.now(UTC) - timedelta(days=45)
    await session.commit()
    recent = await client.post(
        f"/api/marked-papers/{paper['id']}/questions",
        json={
            "question_number": 2,
            "question_text": "Recent evidence",
            "awarded_marks": 1,
            "available_marks": 1,
            "topic_tag": "recent",
            "reviewed": True,
        },
    )
    assert recent.status_code == 201
    monkeypatch.setattr(meter_service, "MAX_EVIDENCE_ROWS", 1)
    bounded_meter = (await client.get("/api/meters/topics")).json()
    assert [item["topic"] for item in bounded_meter] == ["recent"]

    assert (await client.get("/api/marked-papers")).status_code == 200
    assert (await client.get(f"/api/marked-papers/{paper['id']}")).status_code == 200
    principal["user"] = other
    assert (await client.get("/api/marked-papers")).json() == []
    assert (await client.get(f"/api/marked-papers/{paper['id']}")).status_code == 404
    assert (await client.delete(f"/api/marked-papers/{paper['id']}")).status_code == 404
    foreign_patch = await client.patch(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}",
        json={"feedback": "cross tenant"},
    )
    assert foreign_patch.status_code == 404
    foreign_delete = await client.delete(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}"
    )
    assert foreign_delete.status_code == 404
    principal["user"] = owner
    removed_question = await client.delete(
        f"/api/marked-papers/{paper['id']}/questions/{question['id']}"
    )
    assert removed_question.status_code == 200
    assert (await client.delete(f"/api/marked-papers/{paper['id']}")).status_code == 204


@pytest.mark.asyncio
async def test_provider_lifecycle_fixed_target_and_two_user_isolation(m3_client, monkeypatch):
    client, session, owner, other, principal = m3_client
    assert (await client.get("/api/providers")).status_code == 200
    configured = await client.put(
        "/api/providers/settings",
        json={"provider": "openai", "api_key": "test-api-key", "model": "gpt-4o-mini"},
    )
    assert configured.status_code == 200
    assert configured.json()["credential"] == "********"
    assert (await client.get("/api/providers/settings")).status_code == 200
    provider_test_key = str(uuid.uuid4())
    with respx.mock:
        route = respx.get("https://api.openai.com/v1/models")
        route.mock(return_value=Response(200, json={"data": [{"id": "other-model"}]}))
        rejected_model = await client.post(
            "/api/providers/openai/test", headers={"Idempotency-Key": provider_test_key}
        )
        route.mock(return_value=Response(200, json={"data": [{"id": "gpt-4o-mini"}]}))
        tested = await client.post(
            "/api/providers/openai/test", headers={"Idempotency-Key": str(uuid.uuid4())}
        )
        replayed_test = await client.post(
            "/api/providers/openai/test",
            headers={"Idempotency-Key": tested.request.headers["Idempotency-Key"]},
        )
    assert rejected_model.status_code == 200
    assert rejected_model.json()["status"] == "invalid"
    assert rejected_model.json()["last_error"]
    assert tested.status_code == 200
    assert tested.json()["active_for_generation"] is True
    assert replayed_test.json() == tested.json()
    assert route.call_count == 2
    runtime = await provider_service.resolve_generation_provider(owner, session)
    assert runtime.provider == "openai"
    assert runtime.model == "gpt-4o-mini"
    assert runtime.api_key == "test-api-key"

    updated = await client.put(
        "/api/providers/settings",
        json={"provider": "openai", "model": "gpt-4o"},
    )
    assert updated.status_code == 200
    assert updated.json()["status"] == "configured"
    assert updated.json()["active_for_generation"] is False

    azure_endpoint = "https://resource.openai.azure.com"
    allowed_settings = provider_service.get_settings().model_copy(
        update={"provider_allowed_endpoints": azure_endpoint}
    )
    monkeypatch.setattr(provider_service, "get_settings", lambda: allowed_settings)

    async def public_endpoint(_endpoint: str) -> None:
        return None

    monkeypatch.setattr(provider_service, "_ensure_public_endpoint", public_endpoint)
    configured_azure = await client.put(
        "/api/providers/settings",
        json={
            "provider": "azure_openai",
            "api_key": "azure-test-key",
            "model": "course-deployment",
            "endpoint": azure_endpoint,
        },
    )
    assert configured_azure.status_code == 200
    azure_url = (
        f"{azure_endpoint}/openai/deployments/course-deployment/chat/completions"
        "?api-version=2024-10-21"
    )
    with respx.mock:
        azure_probe = respx.post(azure_url).mock(return_value=Response(200, json={}))
        tested_azure = await client.post("/api/providers/azure_openai/test")
    assert tested_azure.status_code == 200
    assert azure_probe.called

    principal["user"] = other
    assert (await client.get("/api/providers/settings")).json() == []
    assert (await client.post("/api/providers/openai/test")).status_code == 404
    assert (await client.delete("/api/providers/openai")).status_code == 404
    principal["user"] = owner
    assert (await client.delete("/api/providers/openai")).status_code == 204


@pytest.mark.asyncio
async def test_custom_provider_endpoint_rejects_private_resolution(monkeypatch):
    monkeypatch.setattr(
        provider_service.socket,
        "getaddrinfo",
        lambda *_args, **_kwargs: [(2, 1, 6, "", ("127.0.0.1", 443))],
    )

    with pytest.raises(WikiBaseError) as exc_info:
        await provider_service._ensure_public_endpoint("https://provider.example")

    assert exc_info.value.error == "unsafe_endpoint"


@pytest.mark.asyncio
async def test_expired_browser_auth_sessions_do_not_consume_pending_quota(m3_client, monkeypatch):
    client, session, owner, _, _ = m3_client
    oauth_settings = provider_service.get_settings().model_copy(
        update={"chatgpt_oauth_client_id": "approved-client"}
    )
    monkeypatch.setattr(provider_service, "get_settings", lambda: oauth_settings)
    monkeypatch.setattr(provider_auth_service, "get_settings", lambda: oauth_settings)
    for _ in range(provider_auth_service.MAX_PENDING_SESSIONS):
        response = await client.post(
            "/api/providers/chatgpt/auth-sessions",
            json={"return_path": "/settings/providers?provider=chatgpt"},
        )
        assert response.status_code == 201
    blocked = await client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    assert blocked.status_code == 429
    sessions = list(
        (
            await session.execute(
                select(ProviderAuthorizationSession).where(
                    ProviderAuthorizationSession.user_id == owner.id
                )
            )
        ).scalars()
    )
    for auth_session in sessions:
        auth_session.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await session.commit()
    replacement = await client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    assert replacement.status_code == 201
    remaining = await session.scalar(
        select(func.count(ProviderAuthorizationSession.id)).where(
            ProviderAuthorizationSession.user_id == owner.id
        )
    )
    assert remaining == 1


@pytest.mark.asyncio
async def test_chatgpt_browser_auth_is_pkce_bound_durable_and_replay_safe(m3_client, monkeypatch):
    client, session, owner, other, principal = m3_client
    oauth_settings = provider_service.get_settings().model_copy(
        update={
            "chatgpt_oauth_client_id": "approved-client",
            "chatgpt_oauth_redirect_uri": ("http://test/api/providers/chatgpt/oauth/callback"),
            "frontend_url": "http://frontend.test",
        }
    )
    monkeypatch.setattr(provider_service, "get_settings", lambda: oauth_settings)
    monkeypatch.setattr(provider_auth_service, "get_settings", lambda: oauth_settings)

    descriptors = (await client.get("/api/providers")).json()
    chatgpt = next(item for item in descriptors if item["id"] == "chatgpt")
    assert chatgpt["auth_methods"] == [
        {
            "kind": "oauth_code",
            "label": "Sign in through browser",
            "recommended": True,
            "enabled": True,
            "unavailable_reason": None,
        }
    ]

    started = await client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    assert started.status_code == 201
    started_payload = started.json()
    authorization_url = urlparse(started_payload["authorization_url"])
    query = parse_qs(authorization_url.query)
    assert query["client_id"] == ["approved-client"]
    assert query["code_challenge_method"] == ["S256"]
    assert query["code_challenge"][0]
    assert "code_verifier" not in query
    state = query["state"][0]
    session_id = started_payload["id"]
    browser_binding = started_payload["browser_binding"]

    principal["user"] = other
    assert (await client.get(f"/api/providers/auth-sessions/{session_id}")).status_code == 404
    principal["user"] = owner

    principal["user"] = other
    mismatched = await client.post(
        "/api/providers/chatgpt/oauth/callback",
        json={
            "state": state,
            "code": "stolen-code",
            "browser_binding": browser_binding,
        },
    )
    assert mismatched.status_code == 403
    principal["user"] = owner
    wrong_browser = await client.post(
        "/api/providers/chatgpt/oauth/callback",
        json={
            "state": state,
            "code": "other-browser-code",
            "browser_binding": "different-browser-binding-value-1234567890",
        },
    )
    assert wrong_browser.status_code == 403

    id_token, jwks = _oauth_identity(query["nonce"][0], "approved-client")
    with respx.mock:
        token_route = respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "access-secret",
                    "refresh_token": "refresh-secret",
                    "expires_in": 900,
                    "id_token": id_token,
                    "scope": "openid profile email offline_access",
                },
            )
        )
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(return_value=Response(200, json=jwks))
        completed = await client.post(
            "/api/providers/chatgpt/oauth/callback",
            json={
                "state": state,
                "code": "one-time-code",
                "browser_binding": browser_binding,
            },
        )
    assert completed.status_code == 200
    assert completed.json()["return_path"] == (
        "/settings/providers?provider=chatgpt&auth=connected"
    )
    request_body = token_route.calls[0].request.content.decode()
    assert "code_verifier=" in request_body
    assert "one-time-code" in request_body

    connected = (await client.get("/api/providers/settings")).json()
    chatgpt_setting = next(item for item in connected if item["provider"] == "chatgpt")
    assert chatgpt_setting["auth_method"] == "oauth_code"
    assert chatgpt_setting["provider_account_label"] == "student@example.com"
    assert chatgpt_setting["status"] == "connected"
    assert chatgpt_setting["active_for_generation"] is True
    assert "access-secret" not in str(chatgpt_setting)
    assert "refresh-secret" not in str(chatgpt_setting)

    replay = await client.post(
        "/api/providers/chatgpt/oauth/callback",
        json={
            "state": state,
            "code": "replayed-code",
            "browser_binding": browser_binding,
        },
    )
    assert replay.status_code == 409

    runtime = await provider_service.resolve_generation_provider(owner, session)
    assert runtime.provider == "chatgpt"
    assert runtime.transport == "responses"
    assert runtime.account_id == "acct-123"
    assert runtime.api_key == "access-secret"

    stored = await session.scalar(
        select(ProviderSetting).where(
            ProviderSetting.user_id == owner.id,
            ProviderSetting.provider == "chatgpt",
        )
    )
    stored.endpoint = "https://attacker.example/steal"
    stored.access_token_expires_at = datetime.now(UTC) + timedelta(minutes=10)
    await session.flush()
    pinned_runtime = await provider_service.resolve_generation_provider(owner, session)
    assert pinned_runtime.endpoint == oauth_settings.chatgpt_responses_endpoint

    async def one_chunk(**_kwargs):
        return [
            RetrievedChunk(
                content="Local evidence",
                score=0.9,
                source_title="Source",
                source_url="",
                source_type="file",
            )
        ]

    class RevokedResponses:
        async def create(self, **_kwargs):
            raise AuthenticationError(
                "revoked",
                response=Response(
                    401,
                    request=Request("POST", oauth_settings.chatgpt_responses_endpoint),
                ),
                body={},
            )

    class RevokedOpenAI:
        def __init__(self, **_kwargs):
            self.responses = RevokedResponses()

    monkeypatch.setattr(chat_router, "retrieve", one_chunk)
    monkeypatch.setattr(llm_service, "AsyncOpenAI", RevokedOpenAI)
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(400, json={"error": "invalid_grant"})
        )
        revoked_chat = await client.post("/api/chat", json={"message": "Use my sources"})
    assert revoked_chat.status_code == 409
    assert revoked_chat.json()["error"] == "reauth_required"
    stored.status = "connected"
    stored.last_error = None
    stored.last_error_code = None

    stored.access_token_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await session.flush()
    with respx.mock:
        refresh_route = respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "rotated-access",
                    "refresh_token": "rotated-refresh",
                    "expires_in": 900,
                },
            )
        )
        refreshed_runtime = await provider_service.resolve_generation_provider(owner, session)
    assert refreshed_runtime.api_key == "rotated-access"
    assert "grant_type=refresh_token" in refresh_route.calls[0].request.content.decode()
    assert stored.last_refreshed_at is not None
    async with async_session_factory() as fresh_session:
        rotated = await fresh_session.scalar(
            select(ProviderSetting).where(ProviderSetting.id == stored.id)
        )
        assert (
            provider_service.decrypt_provider_key(
                rotated.encrypted_refresh_token,
                rotated.encryption_key_id,
                oauth_settings,
            )
            == "rotated-refresh"
        )

    preserved_access = stored.encrypted_access_token
    stored.access_token_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await session.flush()
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "bad-rotation",
                    "refresh_token": {"not": "a token"},
                    "expires_in": "soon",
                },
            )
        )
        with pytest.raises(WikiBaseError) as malformed_info:
            await provider_service.resolve_generation_provider(owner, session)
    assert malformed_info.value.error == "invalid_token_response"
    assert stored.encrypted_access_token == preserved_access

    stored.access_token_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await session.flush()
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(400, json={"error": "invalid_grant"})
        )
        with pytest.raises(WikiBaseError) as exc_info:
            await provider_service.resolve_generation_provider(owner, session)
    assert exc_info.value.error == "reauth_required"
    assert stored.status == "reauth_required"
    assert stored.active_for_generation is True
    with pytest.raises(WikiBaseError) as blocked_generation:
        await provider_service.resolve_generation_provider(owner, session)
    assert blocked_generation.value.error == "reauth_required"
    blocked_chat = await client.post("/api/chat", json={"message": "Use my sources"})
    assert blocked_chat.status_code == 409
    assert blocked_chat.json()["error"] == "reauth_required"

    stored.status = "connected"
    stored.access_token_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    await session.flush()
    test_key = str(uuid.uuid4())
    with respx.mock:
        rejected_refresh = respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(400, json={"error": "invalid_grant"})
        )
        tested = await client.post(
            "/api/providers/chatgpt/test",
            headers={"Idempotency-Key": test_key},
        )
        replayed = await client.post(
            "/api/providers/chatgpt/test",
            headers={"Idempotency-Key": test_key},
        )
    assert tested.status_code == replayed.status_code == 200
    assert tested.json() == replayed.json()
    assert tested.json()["status"] == "reauth_required"
    assert rejected_refresh.call_count == 1


@pytest.mark.asyncio
async def test_concurrent_browser_callbacks_serialize_provider_creation(
    authenticated_m3_clients, monkeypatch
):
    owner_client, _, parallel_owner_client = authenticated_m3_clients
    oauth_settings = provider_service.get_settings().model_copy(
        update={"chatgpt_oauth_client_id": "approved-client"}
    )
    monkeypatch.setattr(provider_service, "get_settings", lambda: oauth_settings)
    monkeypatch.setattr(provider_auth_service, "get_settings", lambda: oauth_settings)
    first, second = await asyncio.gather(
        owner_client.post(
            "/api/providers/chatgpt/auth-sessions",
            json={"return_path": "/settings/providers?provider=chatgpt"},
        ),
        parallel_owner_client.post(
            "/api/providers/chatgpt/auth-sessions",
            json={"return_path": "/settings/providers?provider=chatgpt"},
        ),
    )
    first_query = parse_qs(urlparse(first.json()["authorization_url"]).query)
    second_query = parse_qs(urlparse(second.json()["authorization_url"]).query)
    first_token, first_jwks = _oauth_identity(first_query["nonce"][0], "approved-client")
    second_token, second_jwks = _oauth_identity(second_query["nonce"][0], "approved-client")
    combined_jwks = {"keys": first_jwks["keys"] + second_jwks["keys"]}

    def exchange(request):
        token = first_token if b"code=first-code" in request.content else second_token
        return Response(
            200,
            json={
                "access_token": "shared-access",
                "refresh_token": "shared-refresh",
                "expires_in": 900,
                "id_token": token,
            },
        )

    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(side_effect=exchange)
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(
            return_value=Response(200, json=combined_jwks)
        )
        results = await asyncio.gather(
            owner_client.post(
                "/api/providers/chatgpt/oauth/callback",
                json={
                    "state": first_query["state"][0],
                    "code": "first-code",
                    "browser_binding": first.json()["browser_binding"],
                },
            ),
            parallel_owner_client.post(
                "/api/providers/chatgpt/oauth/callback",
                json={
                    "state": second_query["state"][0],
                    "code": "second-code",
                    "browser_binding": second.json()["browser_binding"],
                },
            ),
        )
    assert [response.status_code for response in results] == [200, 200]
    assert all(response.json()["return_path"].endswith("auth=connected") for response in results)
    settings_response = (await owner_client.get("/api/providers/settings")).json()
    assert len(settings_response) == 1
    assert settings_response[0]["provider"] == "chatgpt"

    configured = await owner_client.put(
        "/api/providers/settings",
        json={"provider": "openai", "api_key": "race-test-key", "model": "gpt-4o-mini"},
    )
    assert configured.status_code == 200
    with respx.mock:
        respx.get("https://api.openai.com/v1/models").mock(
            return_value=Response(200, json={"data": [{"id": "gpt-4o-mini"}]})
        )
        assert (await owner_client.post("/api/providers/openai/test")).status_code == 200
    owner_id = uuid.UUID((await owner_client.get("/api/auth/me")).json()["id"])
    async with async_session_factory() as direct_session:
        await direct_session.execute(
            ProviderSetting.__table__.update()
            .where(ProviderSetting.user_id == owner_id)
            .values(active_for_generation=False)
        )
        await direct_session.commit()

    reconnect = await owner_client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    reconnect_query = parse_qs(urlparse(reconnect.json()["authorization_url"]).query)
    reconnect_token, reconnect_jwks = _oauth_identity(
        reconnect_query["nonce"][0], "approved-client"
    )
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "race-access",
                    "refresh_token": "race-refresh",
                    "expires_in": 900,
                    "id_token": reconnect_token,
                },
            )
        )
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(
            return_value=Response(200, json=reconnect_jwks)
        )
        callback_result, activation_result = await asyncio.gather(
            owner_client.post(
                "/api/providers/chatgpt/oauth/callback",
                json={
                    "state": reconnect_query["state"][0],
                    "code": "race-code",
                    "browser_binding": reconnect.json()["browser_binding"],
                },
            ),
            parallel_owner_client.post("/api/providers/openai/activate"),
        )
    assert callback_result.status_code == activation_result.status_code == 200
    async with async_session_factory() as direct_session:
        active_count = await direct_session.scalar(
            select(func.count(ProviderSetting.id)).where(
                ProviderSetting.user_id == owner_id,
                ProviderSetting.active_for_generation.is_(True),
            )
        )
        assert active_count == 1


@pytest.mark.asyncio
async def test_browser_auth_callback_persists_with_request_scoped_sessions(
    authenticated_m3_clients, monkeypatch
):
    owner_client, other_client, parallel_owner_client = authenticated_m3_clients
    oauth_settings = provider_service.get_settings().model_copy(
        update={
            "chatgpt_oauth_client_id": "approved-client",
            "chatgpt_oauth_redirect_uri": (
                "http://frontend.test/api/providers/chatgpt/oauth/callback"
            ),
        }
    )
    monkeypatch.setattr(provider_service, "get_settings", lambda: oauth_settings)
    monkeypatch.setattr(provider_auth_service, "get_settings", lambda: oauth_settings)
    owner_id = uuid.UUID((await owner_client.get("/api/auth/me")).json()["id"])

    started = await owner_client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    query = parse_qs(urlparse(started.json()["authorization_url"]).query)
    state = query["state"][0]
    browser_binding = started.json()["browser_binding"]
    rejected = await other_client.post(
        "/api/providers/chatgpt/oauth/callback",
        json={
            "state": state,
            "code": "wrong-browser",
            "browser_binding": browser_binding,
        },
    )
    assert rejected.status_code == 403

    id_token, jwks = _oauth_identity(query["nonce"][0], "approved-client")
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "durable-access",
                    "refresh_token": "durable-refresh",
                    "expires_in": 900,
                    "id_token": id_token,
                },
            )
        )
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(return_value=Response(200, json=jwks))
        completed = await owner_client.post(
            "/api/providers/chatgpt/oauth/callback",
            json={
                "state": state,
                "code": "right-browser",
                "browser_binding": browser_binding,
            },
        )
    assert completed.status_code == 200
    settings_response = (await owner_client.get("/api/providers/settings")).json()
    assert settings_response[0]["provider"] == "chatgpt"
    assert settings_response[0]["status"] == "connected"
    async with async_session_factory() as fresh_session:
        persisted = await fresh_session.scalar(
            select(ProviderSetting).where(
                ProviderSetting.user_id == owner_id,
                ProviderSetting.provider == "chatgpt",
            )
        )
        assert persisted is not None
        assert persisted.status == "connected"
        assert persisted.encrypted_access_token is not None

    replacement = await owner_client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    replacement_query = parse_qs(urlparse(replacement.json()["authorization_url"]).query)
    replacement_token, replacement_jwks = _oauth_identity(
        replacement_query["nonce"][0],
        "approved-client",
        account_id="acct-other",
        subject_id="openai-user-other",
    )
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "replacement-access",
                    "refresh_token": "replacement-refresh",
                    "expires_in": 900,
                    "id_token": replacement_token,
                },
            )
        )
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(
            return_value=Response(200, json=replacement_jwks)
        )
        replacement_result = await owner_client.post(
            "/api/providers/chatgpt/oauth/callback",
            json={
                "state": replacement_query["state"][0],
                "code": "replacement-code",
                "browser_binding": replacement.json()["browser_binding"],
            },
        )
    assert replacement_result.json()["return_path"].endswith("auth=failed")
    async with async_session_factory() as fresh_session:
        unchanged = await fresh_session.scalar(
            select(ProviderSetting).where(
                ProviderSetting.user_id == owner_id,
                ProviderSetting.provider == "chatgpt",
            )
        )
        assert unchanged.provider_account_id == "acct-123"
        assert unchanged.provider_subject_id == "openai-user-123"

    forged = await owner_client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    forged_query = parse_qs(urlparse(forged.json()["authorization_url"]).query)
    forged_binding = forged.json()["browser_binding"]
    forged_token, forged_jwks = _oauth_identity(
        forged_query["nonce"][0],
        "approved-client",
        issuer="https://attacker.example",
    )
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "forged-access",
                    "refresh_token": "forged-refresh",
                    "expires_in": 900,
                    "id_token": forged_token,
                },
            )
        )
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(
            return_value=Response(200, json=forged_jwks)
        )
        forged_result = await owner_client.post(
            "/api/providers/chatgpt/oauth/callback",
            json={
                "state": forged_query["state"][0],
                "code": "forged-code",
                "browser_binding": forged_binding,
            },
        )
    assert forged_result.status_code == 200
    assert forged_result.json()["return_path"].endswith("auth=failed")

    oversized = await owner_client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    oversized_query = parse_qs(urlparse(oversized.json()["authorization_url"]).query)
    oversized_token, oversized_jwks = _oauth_identity(
        oversized_query["nonce"][0],
        "approved-client",
        account_id="x" * 256,
    )
    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(
            return_value=Response(
                200,
                json={
                    "access_token": "oversized-access",
                    "refresh_token": "oversized-refresh",
                    "expires_in": 900,
                    "id_token": oversized_token,
                },
            )
        )
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(
            return_value=Response(200, json=oversized_jwks)
        )
        oversized_result = await owner_client.post(
            "/api/providers/chatgpt/oauth/callback",
            json={
                "state": oversized_query["state"][0],
                "code": "oversized-code",
                "browser_binding": oversized.json()["browser_binding"],
            },
        )
    assert oversized_result.status_code == 200
    assert oversized_result.json()["return_path"].endswith("auth=failed")

    reconnect = await owner_client.post(
        "/api/providers/chatgpt/auth-sessions",
        json={"return_path": "/settings/providers?provider=chatgpt"},
    )
    reconnect_query = parse_qs(urlparse(reconnect.json()["authorization_url"]).query)
    reconnect_token, reconnect_jwks = _oauth_identity(
        reconnect_query["nonce"][0], "approved-client"
    )
    exchange_started = asyncio.Event()
    release_exchange = asyncio.Event()

    async def slow_exchange(_request):
        exchange_started.set()
        await release_exchange.wait()
        return Response(
            200,
            json={
                "access_token": "reconnect-access",
                "refresh_token": "reconnect-refresh",
                "expires_in": 900,
                "id_token": reconnect_token,
            },
        )

    with respx.mock:
        respx.post(oauth_settings.chatgpt_oauth_token_url).mock(side_effect=slow_exchange)
        respx.get(oauth_settings.chatgpt_oauth_jwks_url).mock(
            return_value=Response(200, json=reconnect_jwks)
        )
        callback_task = asyncio.create_task(
            owner_client.post(
                "/api/providers/chatgpt/oauth/callback",
                json={
                    "state": reconnect_query["state"][0],
                    "code": "reconnect-code",
                    "browser_binding": reconnect.json()["browser_binding"],
                },
            )
        )
        await exchange_started.wait()
        disconnect_task = asyncio.create_task(
            parallel_owner_client.delete("/api/providers/chatgpt")
        )
        await asyncio.sleep(0.05)
        assert not disconnect_task.done()
        release_exchange.set()
        callback_result, disconnect_result = await asyncio.gather(callback_task, disconnect_task)
    assert callback_result.status_code == 200
    assert disconnect_result.status_code == 204
    assert (await owner_client.get("/api/providers/settings")).json() == []
