import asyncio
import re
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime

import httpx
from cryptography.fernet import Fernet
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings, get_settings
from app.exceptions import CanvasTokenExpiredError
from app.models.user import User


def decrypt_token(encrypted: str, settings: Settings) -> str:
    fernet = Fernet(settings.canvas_token_secret.encode())
    return fernet.decrypt(encrypted.encode()).decode()


def encrypt_token(token: str, settings: Settings) -> str:
    fernet = Fernet(settings.canvas_token_secret.encode())
    return fernet.encrypt(token.encode()).decode()


async def refresh_canvas_token(user: User, db: AsyncSession) -> str:
    settings = get_settings()
    refresh_token = decrypt_token(user.encrypted_refresh_token, settings)

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{settings.canvas_base}/login/oauth2/token",
            data={
                "grant_type": "refresh_token",
                "client_id": settings.canvas_client_id,
                "client_secret": settings.canvas_client_secret,
                "refresh_token": refresh_token,
            },
        )
        if resp.status_code != 200:
            raise CanvasTokenExpiredError()

        data = resp.json()
        new_access = data["access_token"]
        new_refresh = data.get("refresh_token", refresh_token)

        user.encrypted_access_token = encrypt_token(new_access, settings)
        user.encrypted_refresh_token = encrypt_token(new_refresh, settings)
        user.token_expires_at = datetime.now(UTC)
        await db.commit()

        return new_access


def _parse_next_link(link_header: str | None) -> str | None:
    if not link_header:
        return None
    match = re.search(r'<([^>]+)>;\s*rel="next"', link_header)
    return match.group(1) if match else None


class CanvasClient:
    def __init__(
        self,
        access_token: str,
        settings: Settings | None = None,
        refresh_token: Callable[[], Awaitable[str]] | None = None,
    ):
        self._settings = settings or get_settings()
        self._token = access_token
        self._refresh_token = refresh_token
        self._client = httpx.AsyncClient(
            base_url=f"{self._settings.canvas_base}/api/v1",
            headers={"Authorization": f"Bearer {self._token}"},
            timeout=30.0,
        )

    async def close(self):
        await self._client.aclose()

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        await self.close()

    async def _get_paginated(self, path: str, params: dict | None = None) -> list[dict]:
        results = []
        url = path
        query = params or {}

        while url:
            resp = await self._request("GET", url, params=query)
            data = resp.json()
            if isinstance(data, list):
                results.extend(data)
            else:
                results.append(data)

            url = _parse_next_link(resp.headers.get("Link"))
            query = {}

        return results

    async def _request(
        self, method: str, url: str, params: dict | None = None, **kwargs
    ) -> httpx.Response:
        refreshed = False
        for attempt in range(3):
            resp = await self._client.request(method, url, params=params, **kwargs)

            if resp.status_code == 401 and self._refresh_token and not refreshed:
                self._token = await self._refresh_token()
                self._client.headers["Authorization"] = f"Bearer {self._token}"
                refreshed = True
                continue

            remaining = resp.headers.get("X-Rate-Limit-Remaining")
            if remaining and float(remaining) < 10:
                await asyncio.sleep(1.0)

            if resp.status_code == 429:
                wait = min(2**attempt, 10)
                await asyncio.sleep(wait)
                continue

            resp.raise_for_status()
            return resp

        resp.raise_for_status()
        return resp

    async def get_user_courses(self) -> list[dict]:
        return await self._get_paginated(
            "/courses",
            params={"enrollment_state": "active", "per_page": "50"},
        )

    async def get_announcements(self, course_id: int) -> list[dict]:
        return await self._get_paginated(
            f"/courses/{course_id}/discussion_topics",
            params={"only_announcements": "true", "per_page": "50"},
        )

    async def get_assignments(self, course_id: int) -> list[dict]:
        return await self._get_paginated(
            f"/courses/{course_id}/assignments",
            params={"per_page": "50"},
        )

    async def get_files(self, course_id: int) -> list[dict]:
        return await self._get_paginated(
            f"/courses/{course_id}/files",
            params={"per_page": "50"},
        )

    async def get_calendar_events(self, start: datetime, end: datetime) -> list[dict]:
        return await self._get_paginated(
            "/calendar_events",
            params={
                "start_date": start.isoformat(),
                "end_date": end.isoformat(),
                "per_page": "50",
            },
        )

    async def download_file(self, file_url: str) -> bytes:
        async with httpx.AsyncClient(follow_redirects=True, timeout=60.0) as client:
            resp = await client.get(file_url, headers={"Authorization": f"Bearer {self._token}"})
            resp.raise_for_status()
            return resp.content
