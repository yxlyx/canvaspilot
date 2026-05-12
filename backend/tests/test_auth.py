import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from starlette.requests import Request

from app import dependencies
from app.config import Settings
from app.exceptions import UnauthorizedError
from app.models.user import User


class DummyResult:
    def __init__(self, user):
        self._user = user

    def scalar_one_or_none(self):
        return self._user


class DummyDB:
    def __init__(self, user):
        self.user = user

    async def execute(self, statement):
        return DummyResult(self.user)


def make_request(headers: list[tuple[bytes, bytes]] | None = None, session: dict | None = None):
    return Request(
        {
            "type": "http",
            "method": "GET",
            "path": "/",
            "headers": headers or [],
            "session": session or {},
        }
    )


def make_user(user_id: uuid.UUID) -> User:
    return User(
        id=user_id,
        canvas_user_id=1,
        name="Test User",
        email="test@example.com",
        encrypted_access_token="access",
        encrypted_refresh_token="refresh",
        token_expires_at=datetime.now(UTC),
    )


@pytest.mark.asyncio
async def test_get_current_user_with_bearer_token(settings: Settings, monkeypatch):
    user_id = uuid.uuid4()
    user = make_user(user_id)
    monkeypatch.setattr(dependencies, "get_settings", lambda: settings)
    token = dependencies.create_app_token(user_id)
    request = make_request(headers=[(b"authorization", f"Bearer {token}".encode())])

    result = await dependencies.get_current_user(request, DummyDB(user))

    assert result is user


@pytest.mark.asyncio
async def test_get_current_user_with_session_cookie(settings: Settings, monkeypatch):
    user_id = uuid.uuid4()
    user = make_user(user_id)
    monkeypatch.setattr(dependencies, "get_settings", lambda: settings)
    request = make_request(session={"user_id": str(user_id)})

    result = await dependencies.get_current_user(request, DummyDB(user))

    assert result is user


@pytest.mark.asyncio
async def test_get_current_user_rejects_missing_credentials():
    with pytest.raises(UnauthorizedError):
        await dependencies.get_current_user(make_request(), DummyDB(None))


@pytest.mark.asyncio
async def test_get_current_user_rejects_expired_bearer(settings: Settings, monkeypatch):
    monkeypatch.setattr(dependencies, "get_settings", lambda: settings)
    token = jwt.encode(
        {"sub": str(uuid.uuid4()), "exp": datetime.now(UTC) - timedelta(seconds=1)},
        settings.session_secret,
        algorithm=dependencies.JWT_ALGORITHM,
    )

    with pytest.raises(UnauthorizedError):
        await dependencies.get_current_user(
            make_request(headers=[(b"authorization", f"Bearer {token}".encode())]),
            DummyDB(None),
        )


@pytest.mark.asyncio
async def test_get_current_user_rejects_malformed_bearer(settings: Settings, monkeypatch):
    monkeypatch.setattr(dependencies, "get_settings", lambda: settings)

    with pytest.raises(UnauthorizedError):
        await dependencies.get_current_user(
            make_request(headers=[(b"authorization", b"Bearer not-a-jwt")]),
            DummyDB(None),
        )
