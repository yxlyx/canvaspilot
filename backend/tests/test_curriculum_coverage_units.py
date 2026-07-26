import uuid

import pytest
from pydantic import ValidationError

from app.models.source_chunk import SourceChunk
from app.schemas.curriculum import (
    CandidateSourceChunkResponse,
    ManualAssociationRequest,
    ProposalGenerationRequest,
)
from app.services.curriculum_coverage import (
    match_topic_to_chunks,
    normalized_tokens,
    source_fingerprint,
)


def _chunk(index: int, content: str, citation: str = "Week 1") -> SourceChunk:
    return SourceChunk(
        id=uuid.uuid5(uuid.NAMESPACE_URL, f"chunk:{index}:{content}"),
        source_id=uuid.UUID(int=1),
        chunk_index=index,
        citation_ref=citation,
        location_label=f"Section {index}",
        content=content,
        token_count=len(content.split()),
        embedding=None,
    )


def test_normalization_ignores_stop_words_and_requires_meaningful_title_evidence():
    assert normalized_tokens("The DATA-structures and Algorithms") == (
        "data",
        "structures",
        "algorithms",
    )
    assert match_topic_to_chunks("Introduction to data", [_chunk(0, "The data was recorded")]) == (
        0.0,
        [],
    )
    assert match_topic_to_chunks(
        "Graph traversal algorithms", [_chunk(0, "Graph paper and traversal time are discussed")]
    ) == (0.0, [])


def test_conservative_match_returns_exact_bounded_citation_evidence():
    chunk = _chunk(
        2,
        "Breadth first graph traversal algorithms visit each reachable vertex once.",
        "Lecture 4, p. 12",
    )

    strength, evidence = match_topic_to_chunks("Graph traversal algorithms", [chunk])

    assert strength == 1.0
    assert evidence == [
        {
            "chunk_id": str(chunk.id),
            "citation": "Lecture 4, p. 12",
            "excerpt": (
                "Breadth first graph traversal algorithms visit each reachable vertex once."
            ),
            "location": "Section 2",
        }
    ]


def test_source_fingerprint_is_stable_in_canonical_chunk_order_and_sensitive_to_evidence():
    first = _chunk(0, "Arrays support indexed access.", "p. 1")
    second = _chunk(1, "Linked lists support insertion.", "p. 2")

    assert source_fingerprint([second, first]) == source_fingerprint([first, second])
    original = source_fingerprint([first, second])
    second.citation_ref = "p. 3"
    assert source_fingerprint([first, second]) != original
    second.citation_ref = "p. 2"
    second.content += " More detail."
    assert source_fingerprint([first, second]) != original


@pytest.mark.asyncio
async def test_coverage_routes_require_authentication(client):
    enrollment_id = uuid.uuid4()
    responses = [
        await client.get(f"/api/enrollments/{enrollment_id}/coverage"),
        await client.post(f"/api/enrollments/{enrollment_id}/coverage/proposals", json={}),
        await client.get(f"/api/enrollments/{enrollment_id}/candidate-sources"),
        await client.get(
            f"/api/enrollments/{enrollment_id}/candidate-sources/{uuid.uuid4()}/chunks",
            params={"topic_id": uuid.uuid4()},
        ),
    ]
    assert [response.status_code for response in responses] == [401, 401, 401, 401]
    assert all(response.json()["error"] == "unauthorized" for response in responses)


def test_candidate_chunk_schema_enforces_response_bounds():
    chunk = CandidateSourceChunkResponse(
        chunk_id=uuid.uuid4(),
        citation="Lecture 1",
        location="page 2",
        excerpt="Bounded evidence",
        relevance=0.5,
        rank=1,
    )
    assert chunk.relevance == 0.5
    with pytest.raises(ValidationError):
        CandidateSourceChunkResponse(
            chunk_id=uuid.uuid4(),
            citation="Lecture 1",
            location="page 2",
            excerpt="x" * 323,
            relevance=1.1,
            rank=101,
        )


def test_coverage_requests_reject_duplicate_source_and_chunk_ids():
    source_id = uuid.uuid4()
    chunk_id = uuid.uuid4()
    with pytest.raises(ValidationError):
        ProposalGenerationRequest(source_ids=[source_id, source_id])
    with pytest.raises(ValidationError):
        ManualAssociationRequest(
            topic_id=uuid.uuid4(),
            source_id=source_id,
            chunk_ids=[chunk_id, chunk_id],
        )
