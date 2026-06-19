import uuid
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from starlette.requests import Request

from app import dependencies
from app.config import Settings
from app.exceptions import UnauthorizedError
from app.models.user import User
from app.routers.auth import BadAuthRequestError, LoginRequest, RegisterRequest, login, register


class DummyResult:
    def __init__(self, user):
        self._user = user

    def scalar_one_or_none(self):
        return self._user


class DummyDB:
    def __init__(self, user):
        self.user = user
        self.added = None
        self.committed = False

    async def execute(self, statement):
        _ = statement
        return DummyResult(self.user)

    def add(self, user):
        if user.id is None:
            user.id = uuid.uuid4()
        self.added = user
        self.user = user

    async def commit(self):
        self.committed = True

    async def refresh(self, user):
        if user.id is None:
            user.id = uuid.uuid4()


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
        canvas_user_id=None,
        name="Test User",
        email="test@example.com",
        password_hash=None,
        encrypted_access_token=None,
        encrypted_refresh_token=None,
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


@pytest.mark.asyncio
async def test_register_creates_user_and_token(settings: Settings, monkeypatch):
    monkeypatch.setattr(dependencies, "get_settings", lambda: settings)
    request = make_request()
    db = DummyDB(None)

    result = await register(
        RegisterRequest(name="Demo User", email="DEMO@Example.COM ", password="password123"),
        request,
        db,
    )

    assert result.user.email == "demo@example.com"
    assert result.user.name == "Demo User"
    assert result.user.canvas_user_id is None
    assert result.token
    assert db.committed is True
    assert db.added.password_hash != "password123"
    assert request.session["user_id"] == str(result.user.id)


@pytest.mark.asyncio
async def test_register_rejects_duplicate_email():
    db = DummyDB(make_user(uuid.uuid4()))

    with pytest.raises(BadAuthRequestError) as exc:
        await register(
            RegisterRequest(name="Demo User", email="test@example.com", password="password123"),
            make_request(),
            db,
        )

    assert exc.value.error == "email_taken"
    assert exc.value.status_code == 409


@pytest.mark.asyncio
async def test_register_rejects_short_password():
    with pytest.raises(BadAuthRequestError) as exc:
        await register(
            RegisterRequest(name="Demo User", email="demo@example.com", password="short"),
            make_request(),
            DummyDB(None),
        )

    assert exc.value.error == "weak_password"


@pytest.mark.asyncio
async def test_login_accepts_correct_password(settings: Settings, monkeypatch):
    monkeypatch.setattr(dependencies, "get_settings", lambda: settings)
    db = DummyDB(None)
    request = make_request()
    created = await register(
        RegisterRequest(name="Demo User", email="demo@example.com", password="password123"),
        request,
        db,
    )

    login_request = make_request()
    result = await login(
        LoginRequest(email="demo@example.com", password="password123"),
        login_request,
        db,
    )

    assert result.user.id == created.user.id
    assert result.token
    assert login_request.session["user_id"] == str(created.user.id)


@pytest.mark.asyncio
async def test_login_rejects_wrong_password():
    db = DummyDB(None)
    await register(
        RegisterRequest(name="Demo User", email="demo@example.com", password="password123"),
        make_request(),
        db,
    )

    with pytest.raises(BadAuthRequestError) as exc:
        await login(
            LoginRequest(email="demo@example.com", password="wrongpass"),
            make_request(),
            db,
        )

    assert exc.value.error == "invalid_credentials"
    assert exc.value.status_code == 401
