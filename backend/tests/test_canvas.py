from datetime import UTC, datetime

import pytest
import respx
from cryptography.fernet import Fernet
from httpx import Response

from app.config import Settings
from app.models.user import User
from app.services.canvas import CanvasClient, decrypt_token, encrypt_token, refresh_canvas_token


@pytest.mark.asyncio
async def test_canvas_pagination(settings: Settings):
    class FakeResponse:
        def __init__(self, data: list[dict], link: str | None = None):
            self._data = data
            self.headers = {"Link": link} if link else {}

        def json(self):
            return self._data

    calls = []

    async with CanvasClient("token", settings) as client:

        async def fake_request(method: str, url: str, params: dict | None = None, **kwargs):
            calls.append((method, url, params))
            if len(calls) == 1:
                return FakeResponse(
                    [{"id": 1}],
                    '<https://canvas.test.example.com/api/v1/courses?page=2>; rel="next"',
                )
            return FakeResponse([{"id": 2}])

        client._request = fake_request
        courses = await client.get_user_courses()

    assert courses == [{"id": 1}, {"id": 2}]
    assert calls == [
        ("GET", "/courses", {"enrollment_state": "active", "per_page": "50"}),
        ("GET", "https://canvas.test.example.com/api/v1/courses?page=2", {}),
    ]


@pytest.mark.asyncio
async def test_canvas_rate_limit_sleep(settings: Settings, monkeypatch):
    sleeps: list[float] = []

    async def fake_sleep(seconds: float):
        sleeps.append(seconds)

    monkeypatch.setattr("app.services.canvas.asyncio.sleep", fake_sleep)

    with respx.mock(base_url=f"{settings.canvas_base}/api/v1") as router:
        router.get("/courses").mock(
            return_value=Response(200, json=[], headers={"X-Rate-Limit-Remaining": "9"})
        )

        async with CanvasClient("token", settings) as client:
            await client.get_user_courses()

    assert sleeps == [1.0]


@pytest.mark.asyncio
async def test_canvas_429_retry(settings: Settings, monkeypatch):
    sleeps: list[float] = []

    async def fake_sleep(seconds: float):
        sleeps.append(seconds)

    monkeypatch.setattr("app.services.canvas.asyncio.sleep", fake_sleep)

    with respx.mock(base_url=f"{settings.canvas_base}/api/v1") as router:
        route = router.get("/courses").mock(
            side_effect=[Response(429), Response(200, json=[{"id": 1}])]
        )

        async with CanvasClient("token", settings) as client:
            courses = await client.get_user_courses()

    assert courses == [{"id": 1}]
    assert route.call_count == 2
    assert sleeps == [1]


@pytest.mark.asyncio
async def test_canvas_401_refreshes_token(settings: Settings):
    async def refresh():
        return "new-token"

    with respx.mock(base_url=f"{settings.canvas_base}/api/v1") as router:
        route = router.get("/courses").mock(
            side_effect=[Response(401), Response(200, json=[{"id": 1}])]
        )

        async with CanvasClient("old-token", settings, refresh_token=refresh) as client:
            courses = await client.get_user_courses()

    assert courses == [{"id": 1}]
    assert route.calls[0].request.headers["Authorization"] == "Bearer old-token"
    assert route.calls[1].request.headers["Authorization"] == "Bearer new-token"


def test_fernet_encrypt_decrypt_round_trip(settings: Settings):
    settings = settings.model_copy(update={"canvas_token_secret": Fernet.generate_key().decode()})
    token = "canvas-access-token"
    encrypted = encrypt_token(token, settings)

    assert encrypted != token
    assert decrypt_token(encrypted, settings) == token


@pytest.mark.asyncio
async def test_refresh_canvas_token_updates_user(settings: Settings, monkeypatch):
    settings = settings.model_copy(update={"canvas_token_secret": Fernet.generate_key().decode()})
    new_refresh = "new-refresh"
    user = User(
        canvas_user_id=1,
        name="Test User",
        email="test@example.com",
        encrypted_access_token=encrypt_token("old-access", settings),
        encrypted_refresh_token=encrypt_token("old-refresh", settings),
        token_expires_at=datetime.now(UTC),
    )

    class DummyDB:
        committed = False

        async def commit(self):
            self.committed = True

    monkeypatch.setattr("app.services.canvas.get_settings", lambda: settings)

    with respx.mock(base_url=settings.canvas_base) as router:
        router.post("/login/oauth2/token").mock(
            return_value=Response(
                200,
                json={"access_token": "new-access", "refresh_token": new_refresh},
            )
        )

        refreshed = await refresh_canvas_token(user, DummyDB())

    assert refreshed == "new-access"
    assert decrypt_token(user.encrypted_access_token, settings) == "new-access"
    assert decrypt_token(user.encrypted_refresh_token, settings) == new_refresh
