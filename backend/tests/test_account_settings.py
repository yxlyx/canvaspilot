import asyncio
import io
import json
import uuid
import zipfile
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, event, func, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.base import Base
from app.models.m3 import HealthFinding, MarkedPaper, ProviderSetting
from app.models.settings import InAppNotification, UserPreference
from app.models.source import Source, SourceKind, SourceStatus
from app.models.source_chunk import SourceChunk
from app.models.user import User
from app.routers.auth import _hash_password, _verify_password
from app.services.notifications import sync_attention_notifications, upsert_notification
from app.services.preferences import get_preferences_by_user_id


def test_every_direct_user_relationship_declares_database_cascade():
    user_foreign_keys = [
        foreign_key
        for table in Base.metadata.tables.values()
        for foreign_key in table.foreign_keys
        if foreign_key.target_fullname == "users.id"
    ]
    assert user_foreign_keys
    assert all(foreign_key.ondelete == "CASCADE" for foreign_key in user_foreign_keys)


async def _require_database(session: AsyncSession) -> None:
    try:
        await session.execute(text("SELECT 1"))
    except (OSError, SQLAlchemyError) as exc:
        pytest.skip(f"database is unavailable: {exc}")


@pytest.fixture
async def account_client() -> AsyncGenerator[tuple[AsyncClient, AsyncSession, User], None]:
    await engine.dispose()
    async with async_session_factory() as session:
        await _require_database(session)
        email = f"account-settings-{uuid.uuid4().hex}@example.com"
        user = User(
            id=uuid.uuid4(),
            name="Account Owner",
            email=email,
            password_hash=_hash_password("Password123"),
        )
        session.add(user)
        await session.commit()
        user_id = user.id

        async def override_user():
            return user

        async def override_db():
            yield session

        app.dependency_overrides[get_current_user] = override_user
        app.dependency_overrides[get_db] = override_db
        try:
            async with AsyncClient(
                transport=ASGITransport(app=app), base_url="http://test"
            ) as client:
                yield client, session, user
        finally:
            app.dependency_overrides.clear()
            await session.rollback()
            await session.execute(delete(User).where(User.id == user_id))
            await session.commit()
    await engine.dispose()


@pytest.mark.asyncio
async def test_preferences_have_truthful_defaults_and_validate_ranges(account_client):
    client, _, _ = account_client

    initial = await client.get("/api/settings/preferences")
    assert initial.status_code == 200
    assert initial.json() == {
        **initial.json(),
        "theme": "system",
        "motion_preference": "system",
        "daily_review_target": 10,
        "reminder_daily_review": True,
        "reminder_processing_attention": True,
        "reminder_paper_review": True,
        "reminder_health_attention": True,
    }

    saved = await client.patch(
        "/api/settings/preferences",
        json={"theme": "dark", "motion_preference": "reduce", "daily_review_target": 20},
    )
    assert saved.status_code == 200
    assert saved.json()["theme"] == "dark"
    assert saved.json()["motion_preference"] == "reduce"
    assert saved.json()["daily_review_target"] == 20

    fetched = await client.get("/api/settings/preferences")
    assert fetched.json()["theme"] == "dark"
    assert fetched.json()["motion_preference"] == "reduce"
    assert fetched.json()["daily_review_target"] == 20

    invalid = await client.patch("/api/settings/preferences", json={"daily_review_target": 101})
    assert invalid.status_code == 422


@pytest.mark.asyncio
async def test_concurrent_first_preference_requests_create_one_row(account_client):
    _, session, user = account_client

    async def load_preferences() -> uuid.UUID:
        async with async_session_factory() as concurrent_session:
            preferences = await get_preferences_by_user_id(user.id, concurrent_session)
            await concurrent_session.commit()
            return preferences.user_id

    assert await asyncio.gather(load_preferences(), load_preferences()) == [user.id, user.id]
    count = await session.scalar(
        select(func.count(UserPreference.user_id)).where(UserPreference.user_id == user.id)
    )
    assert count == 1


@pytest.mark.asyncio
async def test_password_change_uses_registration_password_policy(account_client):
    client, _, _ = account_client

    response = await client.post(
        "/api/account/password",
        json={"current_password": "Password123", "new_password": "lowercase123"},
    )

    assert response.status_code == 400
    assert response.json()["error"] == "weak_password"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("method", "path", "payload"),
    [
        (
            "POST",
            "/api/account/password",
            {"current_password": "WrongPassword123", "new_password": "Replacement456"},
        ),
        ("POST", "/api/account/export", {"current_password": "WrongPassword123"}),
        (
            "DELETE",
            "/api/account",
            {"current_password": "WrongPassword123", "confirmation": "DELETE"},
        ),
    ],
)
async def test_incorrect_password_confirmation_is_forbidden(account_client, method, path, payload):
    client, _, _ = account_client

    response = await client.request(method, path, json=payload)

    assert response.status_code == 403
    assert response.json()["error"] == "invalid_password"


@pytest.mark.asyncio
async def test_password_change_rotates_auth_version_and_replaces_password(account_client):
    client, session, user = account_client
    original_version = user.auth_version or 0

    response = await client.post(
        "/api/account/password",
        json={"current_password": "Password123", "new_password": "Replacement456"},
    )

    assert response.status_code == 204
    await session.refresh(user)
    assert user.auth_version == original_version + 1
    assert _verify_password("Replacement456", user.password_hash)
    assert not _verify_password("Password123", user.password_hash)


@pytest.mark.asyncio
async def test_notifications_are_deduplicated_by_event(account_client):
    client, session, user = account_client
    source = Source(
        user_id=user.id,
        source_type=SourceKind.PLAIN_TEXT,
        origin="upload",
        title="Failed source",
        citation_label="Failed source",
        status=SourceStatus.FAILED,
        import_error="Parser stopped",
    )
    session.add(source)
    await session.commit()

    first = await client.get("/api/notifications")
    second = await client.get("/api/notifications")
    assert first.status_code == second.status_code == 200
    source_items = [
        item for item in second.json()["items"] if item["kind"] == "processing_attention"
    ]
    assert len(source_items) == 1
    count = await session.scalar(
        select(func.count(InAppNotification.id)).where(
            InAppNotification.user_id == user.id,
            InAppNotification.dedupe_key == f"source-failed:{source.id}",
        )
    )
    assert count == 1

    source.status = SourceStatus.READY
    await session.commit()
    resolved = await client.get("/api/notifications")
    assert all(item["kind"] != "processing_attention" for item in resolved.json()["items"])
    count = await session.scalar(
        select(func.count(InAppNotification.id)).where(
            InAppNotification.user_id == user.id,
            InAppNotification.dedupe_key == f"source-failed:{source.id}",
        )
    )
    assert count == 0


@pytest.mark.asyncio
async def test_notification_sync_uses_constant_database_round_trips(account_client):
    client, session, user = account_client
    session.add_all(
        [
            Source(
                user_id=user.id,
                source_type=SourceKind.PLAIN_TEXT,
                origin="upload",
                title=f"Failed source {index}",
                citation_label=f"Failed source {index}",
                status=SourceStatus.FAILED,
            )
            for index in range(200)
        ]
    )
    await session.commit()

    statements = 0

    def count_statement(*_args):
        nonlocal statements
        statements += 1

    event.listen(engine.sync_engine, "before_cursor_execute", count_statement)
    try:
        response = await client.get("/api/notifications/unread-count")
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", count_statement)

    assert response.status_code == 200
    assert response.json()["unread_count"] == 200
    assert statements <= 20


@pytest.mark.asyncio
async def test_concurrent_notification_syncs_complete_without_duplicates(account_client):
    _, session, user = account_client
    session.add_all(
        [
            Source(
                user_id=user.id,
                source_type=SourceKind.PLAIN_TEXT,
                origin="upload",
                title=f"Concurrent failed source {index}",
                citation_label=f"Concurrent failed source {index}",
                status=SourceStatus.FAILED,
            )
            for index in range(20)
        ]
    )
    await session.commit()

    async def sync_notifications():
        async with async_session_factory() as concurrent_session:
            await sync_attention_notifications(user.id, concurrent_session)
            await concurrent_session.commit()

    await asyncio.wait_for(asyncio.gather(sync_notifications(), sync_notifications()), timeout=5)
    stored = await session.scalar(
        select(func.count(InAppNotification.id)).where(
            InAppNotification.user_id == user.id,
            InAppNotification.kind == "processing_attention",
        )
    )
    assert stored == 20


@pytest.mark.asyncio
async def test_repeated_notification_sync_does_not_rewrite_unchanged_rows(account_client):
    client, session, user = account_client
    source = Source(
        user_id=user.id,
        source_type=SourceKind.PLAIN_TEXT,
        origin="upload",
        title="Stable failed source",
        citation_label="Stable failed source",
        status=SourceStatus.FAILED,
    )
    session.add(source)
    await session.commit()

    assert (await client.get("/api/notifications/unread-count")).status_code == 200
    transaction_before = await session.scalar(
        select(text("xmin::text"))
        .select_from(InAppNotification)
        .where(InAppNotification.dedupe_key == f"source-failed:{source.id}")
    )
    assert (await client.get("/api/notifications/unread-count")).status_code == 200
    transaction_after = await session.scalar(
        select(text("xmin::text"))
        .select_from(InAppNotification)
        .where(InAppNotification.dedupe_key == f"source-failed:{source.id}")
    )

    assert transaction_after == transaction_before


@pytest.mark.asyncio
async def test_single_notification_upsert_does_not_rewrite_unchanged_rows(account_client):
    _, session, user = account_client
    values = {
        "user_id": user.id,
        "kind": "daily_review",
        "title": "Review cards",
        "body": "Review one card.",
        "href": "/flashcards",
        "dedupe_key": "daily-review:stable",
    }
    await upsert_notification(session, **values)
    await session.commit()
    transaction_before = await session.scalar(
        select(text("xmin::text"))
        .select_from(InAppNotification)
        .where(InAppNotification.dedupe_key == values["dedupe_key"])
    )

    await upsert_notification(session, **values)
    await session.commit()
    transaction_after = await session.scalar(
        select(text("xmin::text"))
        .select_from(InAppNotification)
        .where(InAppNotification.dedupe_key == values["dedupe_key"])
    )

    assert transaction_after == transaction_before


@pytest.mark.asyncio
async def test_duplicate_health_findings_create_one_notification(account_client):
    client, session, user = account_client
    session.add_all(
        [
            HealthFinding(
                user_id=user.id,
                code="duplicate_finding",
                severity="warning",
                state="warning",
                resource_type="workspace",
                resource_id=None,
                topic="shared",
                message=f"Finding {index}",
                recommendation="Review it.",
            )
            for index in range(2)
        ]
    )
    await session.commit()

    response = await client.get("/api/notifications")

    assert response.status_code == 200
    matching = [item for item in response.json()["items"] if item["kind"] == "health_attention"]
    assert len(matching) == 1


@pytest.mark.asyncio
async def test_mark_all_materializes_and_reads_latent_notifications(account_client):
    client, session, user = account_client
    session.add(
        Source(
            user_id=user.id,
            source_type=SourceKind.PLAIN_TEXT,
            origin="upload",
            title="Unread failed source",
            citation_label="Unread failed source",
            status=SourceStatus.FAILED,
        )
    )
    await session.commit()

    marked = await client.post("/api/notifications/read-all")
    unread = await client.get("/api/notifications/unread-count")

    assert marked.status_code == 204
    assert unread.status_code == 200
    assert unread.json()["unread_count"] == 0


@pytest.mark.asyncio
async def test_disabled_reminders_remove_existing_attention_notifications(account_client):
    client, session, user = account_client
    paper = MarkedPaper(
        user_id=user.id,
        filename="paper.pdf",
        content_type="application/pdf",
        raw_content=b"paper",
        extraction_status="pending_review",
    )
    finding = HealthFinding(
        user_id=user.id,
        code="missing_citations",
        severity="warning",
        state="warning",
        resource_type="workspace",
        resource_id=None,
        topic=None,
        message="Citations are missing.",
        recommendation="Add citations.",
    )
    daily_key = "daily-review:2000-01-01"
    session.add_all(
        [
            paper,
            finding,
            InAppNotification(
                user_id=user.id,
                kind="daily_review",
                title="Review cards",
                body="Review cards.",
                href="/flashcards",
                dedupe_key=daily_key,
            ),
        ]
    )
    await session.commit()

    created = await client.get("/api/notifications")
    created_kinds = {item["kind"] for item in created.json()["items"]}
    paper_key = f"paper-review:{paper.id}"
    assert {"paper_review", "health_attention"}.issubset(created_kinds)
    assert "daily_review" not in created_kinds
    stored_keys = set(
        await session.scalars(
            select(InAppNotification.dedupe_key).where(InAppNotification.user_id == user.id)
        )
    )
    health_key = next(key for key in stored_keys if key.startswith("health-finding:"))
    assert {paper_key, health_key}.issubset(stored_keys)
    assert daily_key not in stored_keys

    saved = await client.patch(
        "/api/settings/preferences",
        json={
            "reminder_daily_review": False,
            "reminder_paper_review": False,
            "reminder_health_attention": False,
        },
    )
    assert saved.status_code == 200
    synced = await client.get("/api/notifications")
    synced_kinds = {item["kind"] for item in synced.json()["items"]}
    assert not {"daily_review", "paper_review", "health_attention"} & synced_kinds
    stored = await session.scalar(
        select(func.count(InAppNotification.id)).where(
            InAppNotification.user_id == user.id,
            InAppNotification.dedupe_key.in_([daily_key, paper_key, health_key]),
        )
    )
    assert stored == 0


@pytest.mark.asyncio
async def test_account_export_includes_readable_data_and_excludes_secrets(account_client):
    client, session, user = account_client
    session.add(
        ProviderSetting(
            user_id=user.id,
            provider="openai",
            model="gpt-test",
            endpoint="https://api.example.test",
            encrypted_api_key=b"never-export-this-secret",
            encryption_key_id="test-key",
            status="configured",
        )
    )
    await session.commit()

    response = await client.post("/api/account/export", json={"current_password": "Password123"})
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/zip")
    assert b"never-export-this-secret" not in response.content
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        assert "account/profile.json" in archive.namelist()
        providers = json.loads(archive.read("account/providers.json"))
    assert providers == [
        {
            "provider": "openai",
            "model": "gpt-test",
            "endpoint": "https://api.example.test",
            "status": "configured",
            "last_tested_at": None,
        }
    ]


@pytest.mark.asyncio
async def test_account_export_accepts_content_below_archive_limit(account_client):
    client, session, user = account_client
    session.add_all(
        [
            MarkedPaper(
                user_id=user.id,
                filename=f"paper-{index}.pdf",
                content_type="application/pdf",
                raw_content=b"x" * (10 * 1024 * 1024),
                extraction_status="pending_review",
            )
            for index in range(2)
        ]
    )
    await session.commit()

    response = await client.post("/api/account/export", json={"current_password": "Password123"})

    assert response.status_code == 200
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        paper_files = [name for name in archive.namelist() if name.endswith(".pdf")]
    assert len(paper_files) == 2


@pytest.mark.asyncio
async def test_account_export_separates_original_papers_from_metadata(account_client):
    client, session, user = account_client
    paper = MarkedPaper(
        user_id=user.id,
        filename="questions.json",
        content_type="application/json",
        raw_content=b"original paper",
        extraction_status="pending_review",
    )
    session.add(paper)
    await session.commit()

    response = await client.post("/api/account/export", json={"current_password": "Password123"})

    assert response.status_code == 200
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        base = f"marked-papers/{paper.id}"
        assert archive.read(f"{base}/original/questions.json") == b"original paper"
        assert json.loads(archive.read(f"{base}/questions.json")) == []


@pytest.mark.asyncio
async def test_account_export_sorts_parsed_content_by_chunk_index(account_client):
    client, session, user = account_client
    source_id = uuid.uuid4()
    session.add_all(
        [
            Source(
                id=source_id,
                user_id=user.id,
                source_type=SourceKind.PLAIN_TEXT,
                origin="upload",
                title="Ordered source",
                citation_label="Ordered source",
                status=SourceStatus.READY,
            ),
            SourceChunk(
                source_id=source_id,
                chunk_index=1,
                citation_ref="ordered#2",
                location_label="Second",
                content="second content",
                token_count=2,
            ),
            SourceChunk(
                source_id=source_id,
                chunk_index=0,
                citation_ref="ordered#1",
                location_label="First",
                content="first content",
                token_count=2,
            ),
        ]
    )
    await session.commit()

    response = await client.post("/api/account/export", json={"current_password": "Password123"})

    assert response.status_code == 200
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        parsed_content = archive.read(f"sources/{source_id}/parsed-content.md").decode()
    assert parsed_content == "## First\n\nfirst content\n\n## Second\n\nsecond content"


@pytest.mark.asyncio
async def test_account_deletion_cascades_owned_settings_and_notifications(account_client):
    client, session, user = account_client
    user_id = user.id
    session.add_all(
        [
            UserPreference(user_id=user_id),
            InAppNotification(
                user_id=user_id,
                kind="test",
                title="Delete me",
                body="",
                href="/notifications",
                dedupe_key="delete-test",
            ),
            Source(
                user_id=user_id,
                source_type=SourceKind.PLAIN_TEXT,
                origin="upload",
                title="Delete source",
                citation_label="Delete source",
                status=SourceStatus.READY,
            ),
        ]
    )
    await session.commit()

    response = await client.request(
        "DELETE",
        "/api/account",
        json={"current_password": "Password123", "confirmation": "DELETE"},
    )
    assert response.status_code == 204
    assert await session.scalar(select(func.count(User.id)).where(User.id == user_id)) == 0
    assert (
        await session.scalar(
            select(func.count(UserPreference.user_id)).where(UserPreference.user_id == user_id)
        )
        == 0
    )
    assert (
        await session.scalar(
            select(func.count(InAppNotification.id)).where(InAppNotification.user_id == user_id)
        )
        == 0
    )
    assert await session.scalar(select(func.count(Source.id)).where(Source.user_id == user_id)) == 0
