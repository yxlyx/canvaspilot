import os
import uuid
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient

os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault("SESSION_SECRET", "test-session-secret-with-at-least-32-bytes")
os.environ.setdefault("CANVAS_TOKEN_SECRET", "eE-4RX-m39GFpdZXEDBtsaKZoOlMC7EpNlV9XiFrOO8=")
os.environ.setdefault("PROVIDER_ENCRYPTION_SECRET", "XRoe-9icgC8y3-AtmJVDwhbrRraWTUXCsSu013nHztY=")
os.environ.setdefault("SECURE_COOKIES", "false")

from app.config import Settings  # noqa: E402
from app.main import app  # noqa: E402
from app.models.user import User  # noqa: E402

DATABASE_TEST_MODULES = {
    "test_flashcard_drafts_postgresql.py",
    "test_flashcards.py",
    "test_ingestion_jobs.py",
    "test_m3_api.py",
    "test_processing.py",
    "test_retrieval_chat_integration.py",
    "test_search.py",
    "test_source_imports.py",
    "test_sources.py",
    "test_wiki.py",
    "test_account_settings.py",
}


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Identify integration modules that connect to PostgreSQL directly."""
    for item in items:
        if item.path.name in DATABASE_TEST_MODULES:
            item.add_marker(pytest.mark.database)


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """Make service-backed CI fail if any test was skipped."""
    if os.getenv("FAIL_ON_SKIPPED_TESTS") != "1":
        return
    reporter = session.config.pluginmanager.get_plugin("terminalreporter")
    if reporter is not None and reporter.stats.get("skipped"):
        reporter.write_sep("ERROR", "FAIL_ON_SKIPPED_TESTS=1 but the suite skipped tests")
        session.exitstatus = pytest.ExitCode.TESTS_FAILED


@pytest.fixture
def settings():
    return Settings(
        database_url="postgresql+asyncpg://postgres:postgres@localhost:5432/wikibase_test",
        session_secret="test-session-secret-with-at-least-32-bytes",
        canvas_token_secret="eE-4RX-m39GFpdZXEDBtsaKZoOlMC7EpNlV9XiFrOO8=",
        provider_encryption_secret="XRoe-9icgC8y3-AtmJVDwhbrRraWTUXCsSu013nHztY=",
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
        canvas_user_id=None,
        name="Test User",
        email="test@u.nus.edu",
        password_hash=None,
        encrypted_access_token=None,
        encrypted_refresh_token=None,
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
