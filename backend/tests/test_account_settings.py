import io
import json
import uuid
import zipfile
from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete, func, select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import async_session_factory, engine, get_db
from app.dependencies import get_current_user
from app.main import app
from app.models.base import Base
from app.models.m3 import ProviderSetting
from app.models.settings import InAppNotification, UserPreference
from app.models.source import Source, SourceKind, SourceStatus
from app.models.user import User
from app.routers.auth import _hash_password, _verify_password


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

    invalid = await client.patch("/api/settings/preferences", json={"daily_review_target": 101})
    assert invalid.status_code == 422


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
