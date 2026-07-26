import asyncio

import httpx
import pytest
from pydantic import ValidationError

from app.exceptions import WikiBaseError
from app.schemas.curriculum import ImportCommitRequest, ImportPreviewRequest, TopicListUpdate
from app.schemas.settings import UserPreferenceUpdateRequest
from app.services.curriculum import extract_provisional_topics, extract_syllabus_topics
from app.services.nusmods import (
    NUSModsClient,
    parse_share_url,
    reset_nusmods_cache,
    validate_academic_year,
)
from app.services.source_parsers import parse_markdown


@pytest.fixture(autouse=True)
def isolated_nusmods_cache():
    reset_nusmods_cache()
    yield
    reset_nusmods_cache()


def test_parse_nusmods_share_url_normalizes_and_preserves_lesson_provenance():
    parsed = parse_share_url(
        "https://www.nusmods.com/timetable/sem-2/share?cs1010=LEC:1,TUT:3&MA1521=&hidden=CS9999&ta=x"
    )

    assert parsed.semester == 2
    assert [item.code for item in parsed.modules] == ["CS1010", "MA1521"]
    assert parsed.modules[0].lesson_config == {"nusmods_share": "LEC:1,TUT:3"}
    assert parsed.modules[1].lesson_config == {}


@pytest.mark.parametrize(
    "url",
    [
        "http://nusmods.com/timetable/sem-1/share?CS1010=",
        "https://evil.example/timetable/sem-1/share?CS1010=",
        "https://nusmods.com/timetable/sem-5/share?CS1010=",
        "https://nusmods.com:444/timetable/sem-1/share?CS1010=",
        "https://nusmods.com/timetable/sem-1/share?hidden=x&TA=y",
        "https://nusmods.com:bad/timetable/sem-1/share?CS1010=",
    ],
)
def test_parse_nusmods_share_url_rejects_noncanonical_or_empty_urls(url):
    with pytest.raises(WikiBaseError) as error:
        parse_share_url(url)
    assert error.value.error == "invalid_share_url"


def test_parse_nusmods_share_url_enforces_module_and_query_bounds():
    query = "&".join(f"CS{i:02}=x" for i in range(31))
    with pytest.raises(WikiBaseError) as error:
        parse_share_url(f"https://nusmods.com/timetable/sem-1/share?{query}")
    assert error.value.error == "too_many_modules"

    with pytest.raises(WikiBaseError) as error:
        parse_share_url("https://nusmods.com/timetable/sem-1/share?" + "x" * 4097)
    assert error.value.error == "invalid_share_url"


@pytest.mark.parametrize("year", ["2024/2025", "2024-2024", "1999-2000", "20240-20241"])
def test_academic_year_requires_bounded_canonical_form(year):
    with pytest.raises(WikiBaseError) as error:
        validate_academic_year(year)
    assert error.value.error == "invalid_academic_year"


def test_manual_codes_share_validation_and_normalization_path():
    payload = ImportPreviewRequest(
        academic_year="2024-2025", semester=1, module_codes=[" cs1010 ", "CS1010", "ma1521"]
    )
    assert payload.module_codes == ["CS1010", "MA1521"]

    with pytest.raises(ValidationError):
        ImportPreviewRequest(academic_year="2024-2025", module_codes=["CS1010"])
    with pytest.raises(ValidationError):
        ImportPreviewRequest(
            academic_year="2024-2025",
            semester=1,
            module_codes=[f"CS{i:02}" for i in range(31)],
        )


def test_commit_selection_rejects_duplicates_and_overlap():
    with pytest.raises(ValidationError):
        ImportCommitRequest(selected_codes=["CS1010", "cs1010"])
    with pytest.raises(ValidationError):
        ImportCommitRequest(selected_codes=["CS1010"], archive_codes=["CS1010"])


def test_default_scope_rejects_module_and_enrollment_together():
    with pytest.raises(ValidationError):
        UserPreferenceUpdateRequest(
            default_module_id="123e4567-e89b-12d3-a456-426614174000",
            default_enrollment_id="223e4567-e89b-12d3-a456-426614174000",
        )


def test_topic_phrase_extraction_is_fixture_stable_and_versionable():
    fixtures = {
        "This module covers data structures and algorithms; graph traversal.": [
            "data structures and algorithms",
            "graph traversal",
        ],
        "Topics include Linear algebra: Eigenvalues; Matrix factorisation.": [
            "Linear algebra",
            "Eigenvalues",
            "Matrix factorisation",
        ],
    }
    for description, expected in fixtures.items():
        assert extract_provisional_topics(description) == expected
        assert extract_provisional_topics(description) == expected
    assert len(extract_provisional_topics(". ".join(f"Topic {i}" for i in range(50)))) == 12


def test_syllabus_refinement_consumes_real_parser_chunk_representation():
    sections = parse_markdown(
        """# Course syllabus
Overview.

## Week 1: Arrays
Array operations.

## Week 2: Graphs
Graph traversal.
"""
    )

    assert extract_syllabus_topics(sections) == [
        "Course syllabus",
        "Week 1: Arrays",
        "Week 2: Graphs",
    ]


def test_reviewed_topic_list_rejects_duplicates_and_bounds():
    import uuid

    topic_id = uuid.uuid4()
    with pytest.raises(ValidationError):
        TopicListUpdate(
            topics=[
                {"id": topic_id, "title": "One"},
                {"id": topic_id, "title": "Two"},
            ]
        )
    with pytest.raises(ValidationError):
        TopicListUpdate(topics=[])


@pytest.mark.asyncio
async def test_private_curriculum_routes_require_authentication(client):
    response = await client.get("/api/enrollments")
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"


@pytest.mark.asyncio
async def test_nusmods_client_uses_versioned_paths_validates_and_caches_snapshot():
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(str(request.url))
        if request.url.path.endswith("moduleList.json"):
            return httpx.Response(
                200,
                json=[{"moduleCode": "cs1010", "title": "Programming", "semesters": [1, 2]}],
            )
        return httpx.Response(
            200,
            json={
                "moduleCode": "CS1010",
                "title": "Programming",
                "description": "Algorithms.",
                "semesterData": [{"semester": 1, "timetable": [{"lessonType": "Lecture"}]}],
            },
        )

    transport = httpx.MockTransport(handler)
    async with httpx.AsyncClient(transport=transport, follow_redirects=False) as http_client:
        client = NUSModsClient(client=http_client)
        assert (await client.module_list("2024-2025"))[0]["moduleCode"] == "CS1010"
        snapshot = await client.module_snapshot("2024-2025", "cs1010")
        assert snapshot.payload["title"] == "Programming"
        assert len(snapshot.payload_sha256) == 64
        assert (await client.module("2024-2025", "CS1010"))["title"] == "Programming"

    assert requests == [
        "https://api.nusmods.com/v2/2024-2025/moduleList.json",
        "https://api.nusmods.com/v2/2024-2025/modules/CS1010.json",
    ]


@pytest.mark.asyncio
async def test_nusmods_client_retries_transient_responses_with_bound():
    attempts = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if attempts < 3:
            return httpx.Response(503)
        return httpx.Response(
            200,
            json=[{"moduleCode": "CS1010", "title": "Programming", "semesters": [1]}],
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        result = await NUSModsClient(
            client=http_client, max_retries=2, backoff_seconds=0
        ).module_list("2024-2025")
    assert result[0]["moduleCode"] == "CS1010"
    assert attempts == 3


@pytest.mark.asyncio
async def test_nusmods_client_exposes_stable_error_for_invalid_or_oversized_data():
    transport = httpx.MockTransport(
        lambda _request: httpx.Response(200, content=b"[]", headers={"content-length": "4000000"})
    )
    async with httpx.AsyncClient(transport=transport) as http_client:
        with pytest.raises(WikiBaseError) as error:
            await NUSModsClient(client=http_client).module_list("2024-2025")
    assert error.value.error == "nusmods_invalid_response"


@pytest.mark.asyncio
async def test_nusmods_cache_coalesces_concurrent_misses_across_clients():
    attempts = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        return httpx.Response(
            200,
            json={
                "moduleCode": "CS1010",
                "title": "Programming",
                "description": "Algorithms.",
                "semesterData": [{"semester": 1}],
            },
        )

    transport = httpx.MockTransport(handler)
    async with (
        httpx.AsyncClient(transport=transport) as first_http,
        httpx.AsyncClient(transport=transport) as second_http,
    ):
        first = NUSModsClient(client=first_http)
        second = NUSModsClient(client=second_http)
        snapshots = await asyncio.gather(
            first.module_snapshot("2024-2025", "CS1010"),
            second.module_snapshot("2024-2025", "CS1010"),
        )

    assert attempts == 1
    assert snapshots[0] == snapshots[1]


@pytest.mark.asyncio
async def test_nusmods_cache_expires_and_negative_caches_404(monkeypatch):
    import app.services.nusmods as nusmods

    attempts = 0
    status_code = 404

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if status_code == 404:
            return httpx.Response(404)
        return httpx.Response(
            200,
            json={
                "moduleCode": "CS1010",
                "title": "Programming",
                "description": "Algorithms.",
                "semesterData": [{"semester": 1}],
            },
        )

    monkeypatch.setattr(nusmods, "NEGATIVE_CACHE_TTL_SECONDS", 0.01)
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        client = NUSModsClient(client=http_client)
        assert await client.module("2024-2025", "CS1010") is None
        assert await client.module("2024-2025", "CS1010") is None
        assert attempts == 1
        await asyncio.sleep(0.02)
        status_code = 200
        assert (await client.module("2024-2025", "CS1010"))["title"] == "Programming"

    assert attempts == 2
