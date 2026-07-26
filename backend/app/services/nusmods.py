import asyncio
import hashlib
import json
import re
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qsl, urlsplit

import httpx

from app.exceptions import WikiBaseError

MAX_MODULES = 30
MAX_URL_LENGTH = 8192
MAX_QUERY_LENGTH = 4096
MODULE_CODE_RE = re.compile(r"^[A-Z0-9]{2,16}$")
ACADEMIC_YEAR_RE = re.compile(r"^(\d{4})-(\d{4})$")
SHARE_PATH_RE = re.compile(r"^/timetable/sem-([1-4])/share/?$")
RESERVED_KEYS = {"hidden", "ta"}
TRANSIENT_STATUSES = {408, 429, 500, 502, 503, 504}
CACHE_MAX_ENTRIES = 256
CACHE_TTL_SECONDS = 300.0
NEGATIVE_CACHE_TTL_SECONDS = 30.0
_CACHE_MISS = object()
_CACHE: OrderedDict[str, tuple[float, Any | None]] = OrderedDict()
_INFLIGHT: dict[str, asyncio.Task[Any | None]] = {}


@dataclass(frozen=True)
class ShareModule:
    code: str
    lesson_config: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class ParsedShare:
    semester: int
    modules: tuple[ShareModule, ...]


@dataclass(frozen=True)
class ProviderSnapshot:
    payload: Any
    provider_version: str
    source_url: str
    fetched_at: datetime
    payload_sha256: str


def canonical_payload_sha256(payload: Any) -> str:
    encoded = json.dumps(
        payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def reset_nusmods_cache() -> None:
    """Clear process cache state; intended for deterministic test isolation."""
    _CACHE.clear()
    for task in _INFLIGHT.values():
        task.cancel()
    _INFLIGHT.clear()


def validate_academic_year(value: str) -> str:
    match = ACADEMIC_YEAR_RE.fullmatch(value)
    if (
        not match
        or int(match.group(2)) != int(match.group(1)) + 1
        or not 2000 <= int(match.group(1)) <= 2100
    ):
        raise WikiBaseError(400, "invalid_academic_year", "Use consecutive years in YYYY-YYYY form")
    return value


def parse_share_url(value: str) -> ParsedShare:
    if len(value) > MAX_URL_LENGTH:
        raise WikiBaseError(400, "invalid_share_url", "NUSMods share URL is too long")
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError:
        raise WikiBaseError(400, "invalid_share_url", "Invalid NUSMods share URL") from None
    if (
        parsed.scheme != "https"
        or hostname not in {"nusmods.com", "www.nusmods.com"}
        or port not in {None, 443}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise WikiBaseError(400, "invalid_share_url", "Only HTTPS NUSMods share URLs are accepted")
    path_match = SHARE_PATH_RE.fullmatch(parsed.path)
    if not path_match:
        raise WikiBaseError(400, "invalid_share_url", "Invalid NUSMods timetable share path")
    if len(parsed.query) > MAX_QUERY_LENGTH:
        raise WikiBaseError(400, "invalid_share_url", "NUSMods share query is too long")
    try:
        pairs = parse_qsl(parsed.query, keep_blank_values=True, max_num_fields=100)
    except ValueError:
        raise WikiBaseError(
            400, "invalid_share_url", "NUSMods share query has too many fields"
        ) from None

    modules: dict[str, dict[str, str]] = {}
    for raw_key, raw_value in pairs:
        key = raw_key.strip()
        if key.casefold() in RESERVED_KEYS:
            continue
        code = key.upper()
        if not MODULE_CODE_RE.fullmatch(code):
            continue
        if len(raw_value) > 500:
            raise WikiBaseError(400, "invalid_share_url", "Lesson configuration is too long")
        modules.setdefault(code, {})
        if raw_value:
            modules[code]["nusmods_share"] = raw_value
        if len(modules) > MAX_MODULES:
            raise WikiBaseError(
                400, "too_many_modules", f"At most {MAX_MODULES} modules may be imported"
            )
    if not modules:
        raise WikiBaseError(400, "invalid_share_url", "NUSMods share URL contains no modules")
    return ParsedShare(
        semester=int(path_match.group(1)),
        modules=tuple(ShareModule(code, config) for code, config in modules.items()),
    )


class NUSModsClient:
    base_url = "https://api.nusmods.com/v2"

    def __init__(
        self,
        *,
        timeout_seconds: float = 8.0,
        client: httpx.AsyncClient | None = None,
        max_retries: int = 2,
        backoff_seconds: float = 0.1,
    ):
        self._owned_client = client is None
        self._client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(timeout_seconds), follow_redirects=False
        )
        self._max_retries = max(0, min(max_retries, 4))
        self._backoff_seconds = max(0.0, min(backoff_seconds, 2.0))

    async def aclose(self) -> None:
        if self._owned_client:
            await self._client.aclose()

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        await self.aclose()

    async def _get_snapshot(self, path: str, *, max_bytes: int) -> ProviderSnapshot | None:
        key = f"{self.base_url}/{path}"
        now = time.monotonic()
        cached = _CACHE.get(key, _CACHE_MISS)
        if cached is not _CACHE_MISS:
            expires_at, value = cached
            if expires_at > now:
                _CACHE.move_to_end(key)
                return value
            del _CACHE[key]

        task = _INFLIGHT.get(key)
        if task is None:
            task = asyncio.create_task(self._fetch_snapshot(path, max_bytes=max_bytes))
            _INFLIGHT[key] = task
        try:
            snapshot = await asyncio.shield(task)
        finally:
            if task.done() and _INFLIGHT.get(key) is task:
                del _INFLIGHT[key]
        ttl = NEGATIVE_CACHE_TTL_SECONDS if snapshot is None else CACHE_TTL_SECONDS
        _CACHE[key] = (time.monotonic() + ttl, snapshot)
        _CACHE.move_to_end(key)
        while len(_CACHE) > CACHE_MAX_ENTRIES:
            _CACHE.popitem(last=False)
        return snapshot

    async def _fetch_snapshot(self, path: str, *, max_bytes: int) -> ProviderSnapshot | None:
        url = f"{self.base_url}/{path}"
        for attempt in range(self._max_retries + 1):
            try:
                async with self._client.stream("GET", url) as response:
                    if response.status_code == 404:
                        return None
                    if response.is_redirect:
                        raise WikiBaseError(
                            502, "nusmods_unavailable", "NUSMods catalog is temporarily unavailable"
                        )
                    if response.status_code != 200:
                        if (
                            response.status_code in TRANSIENT_STATUSES
                            and attempt < self._max_retries
                        ):
                            await response.aread()
                            await asyncio.sleep(self._backoff_seconds * (2**attempt))
                            continue
                        raise WikiBaseError(
                            502, "nusmods_unavailable", "NUSMods catalog is temporarily unavailable"
                        )
                    declared = response.headers.get("content-length")
                    if declared and int(declared) > max_bytes:
                        raise WikiBaseError(
                            502, "nusmods_invalid_response", "NUSMods response is too large"
                        )
                    body = bytearray()
                    async for chunk in response.aiter_bytes():
                        body.extend(chunk)
                        if len(body) > max_bytes:
                            raise WikiBaseError(
                                502, "nusmods_invalid_response", "NUSMods response is too large"
                            )
                    try:
                        payload = httpx.Response(200, content=bytes(body)).json()
                    except ValueError:
                        raise WikiBaseError(
                            502,
                            "nusmods_invalid_response",
                            "NUSMods returned invalid catalog data",
                        ) from None
                    return ProviderSnapshot(
                        payload=payload,
                        provider_version="v2",
                        source_url=url,
                        fetched_at=datetime.now(UTC),
                        payload_sha256=canonical_payload_sha256(payload),
                    )
            except WikiBaseError:
                raise
            except (httpx.HTTPError, TimeoutError, ValueError):
                if attempt < self._max_retries:
                    await asyncio.sleep(self._backoff_seconds * (2**attempt))
                    continue
                raise WikiBaseError(
                    502, "nusmods_unavailable", "NUSMods catalog is temporarily unavailable"
                ) from None
        raise AssertionError("retry loop did not return")

    async def _get_json(self, path: str, *, max_bytes: int) -> Any | None:
        snapshot = await self._get_snapshot(path, max_bytes=max_bytes)
        return None if snapshot is None else snapshot.payload

    async def module_list(self, academic_year: str) -> list[dict]:
        academic_year = validate_academic_year(academic_year)
        snapshot = await self._get_snapshot(f"{academic_year}/moduleList.json", max_bytes=3_000_000)
        data = None if snapshot is None else snapshot.payload
        if not isinstance(data, list) or len(data) > 10_000:
            raise WikiBaseError(
                502, "nusmods_invalid_response", "NUSMods returned invalid catalog data"
            )
        result = []
        for item in data:
            if not isinstance(item, dict):
                raise WikiBaseError(
                    502, "nusmods_invalid_response", "NUSMods returned invalid catalog data"
                )
            code = item.get("moduleCode")
            title = item.get("title")
            semesters = item.get("semesters", [])
            if (
                not isinstance(code, str)
                or not MODULE_CODE_RE.fullmatch(code.upper())
                or not isinstance(title, str)
                or len(title) > 500
                or not isinstance(semesters, list)
                or any(
                    not isinstance(value, int) or value not in range(1, 5) for value in semesters
                )
            ):
                raise WikiBaseError(
                    502, "nusmods_invalid_response", "NUSMods returned invalid catalog data"
                )
            result.append({"moduleCode": code.upper(), "title": title, "semesters": semesters})
        return result

    @staticmethod
    def _validate_module_payload(data: Any, code: str) -> dict:
        if not isinstance(data, dict):
            raise WikiBaseError(
                502, "nusmods_invalid_response", "NUSMods returned invalid module data"
            )
        returned_code = data.get("moduleCode")
        title = data.get("title")
        description = data.get("description", "")
        semester_data = data.get("semesterData", [])
        valid_semesters = (
            isinstance(semester_data, list)
            and len(semester_data) <= 4
            and all(
                isinstance(item, dict)
                and isinstance(item.get("semester"), int)
                and item["semester"] in range(1, 5)
                and (
                    "timetable" not in item
                    or (
                        isinstance(item["timetable"], list)
                        and len(item["timetable"]) <= 10_000
                        and all(isinstance(entry, dict) for entry in item["timetable"])
                    )
                )
                for item in semester_data
            )
            and len({item["semester"] for item in semester_data}) == len(semester_data)
        )
        if (
            not isinstance(returned_code, str)
            or returned_code.upper() != code
            or not isinstance(title, str)
            or not title
            or len(title) > 500
            or not isinstance(description, str)
            or len(description) > 100_000
            or not valid_semesters
        ):
            raise WikiBaseError(
                502, "nusmods_invalid_response", "NUSMods returned invalid module data"
            )
        return {
            "moduleCode": code,
            "title": title,
            "description": description,
            "semesterData": semester_data,
        }

    async def module_snapshot(self, academic_year: str, code: str) -> ProviderSnapshot | None:
        academic_year = validate_academic_year(academic_year)
        code = code.upper()
        if not MODULE_CODE_RE.fullmatch(code):
            raise WikiBaseError(400, "invalid_module_code", "Invalid module code")
        snapshot = await self._get_snapshot(
            f"{academic_year}/modules/{code}.json", max_bytes=1_000_000
        )
        if snapshot is None:
            return None
        payload = self._validate_module_payload(snapshot.payload, code)
        return ProviderSnapshot(
            payload=payload,
            provider_version=snapshot.provider_version,
            source_url=snapshot.source_url,
            fetched_at=snapshot.fetched_at,
            payload_sha256=canonical_payload_sha256(payload),
        )

    async def module(self, academic_year: str, code: str) -> dict | None:
        snapshot = await self.module_snapshot(academic_year, code)
        return None if snapshot is None else snapshot.payload
