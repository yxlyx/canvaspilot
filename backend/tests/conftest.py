import uuid
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.main import app
from app.models.user import User


@pytest.fixture
def settings():
    return Settings(
        database_url="postgresql+asyncpg://postgres:postgres@localhost:5432/canvaspilot_test",
        session_secret="test-session-secret-with-at-least-32-bytes",
        canvas_token_secret="dGVzdC1mZXJuZXQta2V5LW5vdC1mb3ItcHJvZHVjdGlvbg==",
        canvas_base_url="https://canvas.test.example.com",
        canvas_client_id="test-client",
        canvas_client_secret="test-secret",
        openai_api_key="test-key",
        frontend_url="http://localhost:3000",
    )


@pytest.fixture
def mock_user():
    return User(
        id=uuid.uuid4(),
        canvas_user_id=12345,
        name="Test User",
        email="test@u.nus.edu",
        encrypted_access_token="encrypted",
        encrypted_refresh_token="encrypted",
        token_expires_at=datetime.now(UTC),
    )


@pytest.fixture
def authed_client(mock_user):
    async def _override_get_current_user():
        return mock_user

    from app.dependencies import get_current_user

    app.dependency_overrides[get_current_user] = _override_get_current_user
    yield
    app.dependency_overrides.clear()


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
