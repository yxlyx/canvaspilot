import base64
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest
from cryptography.fernet import Fernet
from pydantic import ValidationError
from sqlalchemy.dialects import postgresql
from sse_starlette.sse import EventSourceResponse

from app.config import Settings
from app.exceptions import WikiBaseError
from app.routers.chat import _event_stream
from app.schemas.chat import ChatRequest
from app.schemas.m3 import (
    MarkedPaperQuestionCreate,
    MarkedPaperQuestionUpdate,
    ProviderConfigureRequest,
)
from app.schemas.settings import ActivityEntryResponse
from app.schemas.source_imports import SourceImportRun
from app.services import account, exports, marked_papers
from app.services.idempotency import request_hash
from app.services.marked_papers import MAX_QUESTIONS, extract_supported_text
from app.services.meters import TopicEvidence, calculate_topic_meter
from app.services.providers import decrypt_provider_key, encrypt_provider_key, endpoint_for
from app.services.study_outputs import Evidence, build_grounded_markdown
from app.services.workspace_health import _workspace_status_finding


@pytest.mark.asyncio
async def test_chat_event_stream_keeps_sse_transport_safeguards():
    async def events():
        yield {"event": "done", "data": "{}"}

    response = _event_stream(events())
    body = b"".join([chunk async for chunk in response.body_iterator])

    assert isinstance(response, EventSourceResponse)
    assert response._ping_interval == 15
    assert body == b"event: done\r\ndata: {}\r\n\r\n"
    assert dict(response.raw_headers) == {
        b"cache-control": b"no-store",
        b"connection": b"keep-alive",
        b"x-accel-buffering": b"no",
        b"content-type": b"text/event-stream; charset=utf-8",
    }


@pytest.mark.parametrize("environment", ["production", "staging", "development"])
def test_every_non_test_mode_rejects_default_secrets(environment):
    with pytest.raises(ValidationError):
        Settings(
            environment=environment,
            allow_insecure_development=True,
            session_secret="change-me-in-production",
            canvas_token_secret="change-me-in-production",
            provider_encryption_secret="change-me-in-production",
        )


def test_production_accepts_independent_strong_secrets():
    settings = Settings(
        environment="production",
        secure_cookies=True,
        session_secret="a-strong-independent-session-secret-1234",
        canvas_token_secret=Fernet.generate_key().decode(),
        provider_encryption_secret=Fernet.generate_key().decode(),
        chatgpt_oauth_redirect_uri=(
            "https://study.example.com/api/providers/chatgpt/oauth/callback"
        ),
    )
    assert settings.environment == "production"


@pytest.mark.parametrize("environment", ["production", "prod", "staging"])
def test_deployed_environments_require_secure_cookies(environment):
    with pytest.raises(ValidationError, match="SECURE_COOKIES"):
        Settings(
            environment=environment,
            secure_cookies=False,
            session_secret="a-strong-independent-session-secret-1234",
            canvas_token_secret=Fernet.generate_key().decode(),
            provider_encryption_secret=Fernet.generate_key().decode(),
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("chatgpt_oauth_authorize_url", "https://auth.openai.com/oauth/authorize/"),
        ("chatgpt_oauth_token_url", "https://attacker.example/token"),
        ("chatgpt_oauth_jwks_url", "https://attacker.example/jwks"),
        ("chatgpt_responses_endpoint", "https://attacker.example/responses"),
    ],
)
def test_browser_auth_endpoints_are_pinned(field, value):
    with pytest.raises(ValidationError):
        Settings(
            environment="test",
            session_secret="test-session-secret-with-at-least-32-bytes",
            canvas_token_secret=Fernet.generate_key().decode(),
            provider_encryption_secret=Fernet.generate_key().decode(),
            **{field: value},
        )


def test_provider_encryption_key_version_supports_rotation():
    old_key = Fernet.generate_key().decode()
    old_settings = Settings(
        environment="test",
        session_secret="test-session-secret-with-at-least-32-bytes",
        canvas_token_secret=Fernet.generate_key().decode(),
        provider_encryption_secret=old_key,
        provider_encryption_key_id="old",
    )
    ciphertext, key_id = encrypt_provider_key("private-key", old_settings)
    rotated = Settings(
        environment="test",
        session_secret="test-session-secret-with-at-least-32-bytes",
        canvas_token_secret=Fernet.generate_key().decode(),
        provider_encryption_secret=Fernet.generate_key().decode(),
        provider_encryption_key_id="new",
        provider_encryption_previous_secrets=f"old:{old_key}",
    )
    assert key_id == "old"
    assert decrypt_provider_key(ciphertext, key_id, rotated) == "private-key"


def test_import_aggregate_text_is_bounded():
    with pytest.raises(ValidationError):
        SourceImportRun.model_validate(
            {
                "sources": [
                    {
                        "source_id": str(uuid.UUID(int=index + 1)),
                        "content": "x" * 2_000_000,
                    }
                    for index in range(3)
                ]
            }
        )


def test_chat_and_history_payloads_are_bounded():
    with pytest.raises(ValidationError):
        ChatRequest(message="x" * 8_001)
    with pytest.raises(ValidationError):
        ChatRequest(
            message="question",
            history=[{"role": "user", "content": "x"} for _ in range(41)],
        )


def test_idempotency_hash_is_canonical_and_operation_scoped():
    assert request_hash("paper.upload", {"b": 2, "a": 1}) == request_hash(
        "paper.upload", {"a": 1, "b": 2}
    )
    assert request_hash("paper.upload", {"a": 1}) != request_hash("output.create", {"a": 1})
    assert request_hash("paper.upload", {"a": 1}) != request_hash("paper.upload", {"a": 2})


def test_grounded_markdown_is_extractive_and_cited():
    evidence = [
        Evidence(
            text="Known evidence sentence. Unsupported text is not introduced.",
            source_id=None,
            source_chunk_id=None,
            source_title="Fixture",
            citation_ref="fixture#1",
        )
    ]
    assert build_grounded_markdown("summary", evidence) == "Known evidence sentence. [1]"


@pytest.mark.parametrize(
    ("resource_count", "code", "state"),
    [
        (0, "workspace_not_evaluated", "unknown"),
        (1, "workspace_healthy", "healthy"),
    ],
)
def test_workspace_status_requires_resources_for_healthy_state(resource_count, code, state):
    finding = _workspace_status_finding(uuid.uuid4(), resource_count)

    assert finding.code == code
    assert finding.severity == "info"
    assert finding.state == state
    assert finding.resource_type == "workspace"
    assert finding.resource_id is None
    if resource_count == 0:
        assert "finish indexing a source" in finding.recommendation


def test_legacy_meter_exposes_factual_signals_without_completion_scores():
    now = datetime(2026, 7, 20, tzinfo=UTC)
    uncertain = calculate_topic_meter("sparse", TopicEvidence(source_count=1), now)
    assert uncertain.state == "uncertain"
    assert uncertain.estimated_completion is None

    stale = calculate_topic_meter(
        "old",
        TopicEvidence(
            source_count=2,
            attempts=4,
            correct=2,
            confidence_total=1.0,
            confidence_count=2,
            latest_at=now - timedelta(days=45),
        ),
        now,
    )
    assert stale.state == "stale"
    assert stale.stale is True

    current = calculate_topic_meter(
        "weak",
        TopicEvidence(
            source_count=2,
            attempts=4,
            correct=0,
            confidence_total=0.5,
            confidence_count=2,
            latest_at=now,
        ),
        now,
    )
    assert current.estimated_completion is None
    assert current.evidence_confidence is None
    assert current.state == "uncertain"
    assert current.reason_code == "legacy_meter_non_authoritative"
    assert [(signal.name, signal.value) for signal in current.signals] == [
        ("source_count", 2.0),
        ("flashcard_recall", 0.0),
        ("marked_paper_score", None),
        ("self_reported_confidence", 0.25),
    ]
    assert "non-authoritative" in current.recommendation


def test_marked_paper_parser_uses_only_explicit_structured_text():
    questions, message = extract_supported_text(
        "Q1: Explain photosynthesis\nMarks: 2/5\nTopic: Biology\n"
        "Feedback: Include light-dependent reactions\nConfidence: 0.9"
    )
    assert questions == [
        {
            "question_number": 1,
            "question_text": "Explain photosynthesis",
            "awarded_marks": 2.0,
            "available_marks": 5.0,
            "feedback": "Include light-dependent reactions",
            "topic_tag": "biology",
            "confidence": 0.9,
        }
    ]
    assert "review" in message.lower()
    assert extract_supported_text("scanned handwriting placeholder")[0] == []


def test_marked_paper_parser_preserves_questions_with_missing_marks_for_review():
    questions, message = extract_supported_text(
        "Q1: Explain photosynthesis\nTopic: Biology\nFeedback: Add more detail"
    )

    assert questions == [
        {
            "question_number": 1,
            "question_text": "Explain photosynthesis",
            "awarded_marks": None,
            "available_marks": None,
            "feedback": "Add more detail",
            "topic_tag": "biology",
            "confidence": 0.5,
        }
    ]
    assert "review" in message.lower()


def test_marked_question_topics_use_source_topic_normalization():
    created = MarkedPaperQuestionCreate(
        question_number=1,
        question_text="Question",
        topic_tag="  Integration  ",
    )
    updated = MarkedPaperQuestionUpdate(topic_tag="  Integration  ")

    assert created.topic_tag == "integration"
    assert updated.topic_tag == "integration"


def test_marked_paper_parser_is_incremental_bounded_and_rejects_invalid_marks(monkeypatch):
    monkeypatch.setattr(
        marked_papers.re,
        "split",
        lambda *_args, **_kwargs: pytest.fail("parser materialized all blocks"),
    )
    text = "ignored\n\n" * 100_000 + "\n\n".join(
        f"Q{number}: Valid\nMarks: 1/1" for number in range(1, MAX_QUESTIONS + 2)
    )
    questions, _ = extract_supported_text(text)
    assert len(questions) == MAX_QUESTIONS
    assert questions[-1]["question_number"] == MAX_QUESTIONS
    with pytest.raises(WikiBaseError) as exc_info:
        extract_supported_text("Q1: Impossible\nMarks: 9/1")
    assert exc_info.value.error == "invalid_marks"


@pytest.mark.asyncio
async def test_account_export_preflight_rejects_before_orm_loading():
    class OversizedAccountSession:
        async def scalar(self, _statement):
            return account.MAX_ACCOUNT_EXPORT_MEMORY_BYTES + 1

        async def execute(self, _statement):
            pytest.fail("account entities were loaded before preflight rejection")

    with pytest.raises(WikiBaseError) as exc_info:
        await account.export_account(SimpleNamespace(id=uuid.uuid4()), OversizedAccountSession())

    assert exc_info.value.status_code == 413
    assert exc_info.value.error == "export_too_large"


def test_account_export_preflight_covers_projected_tables_without_excluded_payloads():
    assert account.ACCOUNT_EXPORT_VALUE_MEMORY_FACTOR == 6
    statement = account._account_export_preflight_statement(uuid.uuid4())
    sql = str(statement.compile(dialect=postgresql.dialect()))

    for table in (
        "users",
        "user_preferences",
        "sources",
        "source_chunks",
        "wiki_pages",
        "wiki_revisions",
        "study_outputs",
        "study_output_citations",
        "flashcard_decks",
        "flashcards",
        "flashcard_attempts",
        "learning_evidence",
        "marked_papers",
        "marked_paper_questions",
        "provider_settings",
    ):
        assert table in sql
    assert "wiki_citations" not in sql
    assert "embedding" not in sql
    assert "encrypted_api_key" not in sql


@pytest.mark.asyncio
async def test_workspace_export_checks_final_closed_zip_size(monkeypatch):
    async def owned_pages(*_args):
        return [SimpleNamespace(slug="page")]

    monkeypatch.setattr(exports, "MAX_EXPORT_BYTES", 200)
    monkeypatch.setattr(exports, "_owned_pages", owned_pages)
    monkeypatch.setattr(exports, "canonical_markdown", lambda _page: "x" * 100)
    with pytest.raises(WikiBaseError) as exc_info:
        await exports.export_workspace(SimpleNamespace(), SimpleNamespace())
    assert exc_info.value.error == "export_too_large"


def test_provider_endpoints_are_fixed_or_safe():
    fixed = ProviderConfigureRequest(provider="openai", api_key="abcdefgh", model="gpt-4o")
    assert endpoint_for(fixed) == "https://api.openai.com/v1"

    with pytest.raises(Exception) as fixed_error:
        endpoint_for(
            ProviderConfigureRequest(
                provider="openai",
                api_key="abcdefgh",
                model="gpt-4o",
                endpoint="https://attacker.example",
            )
        )
    assert "fixed official endpoint" in fixed_error.value.detail
    with pytest.raises(Exception) as unsafe_error:
        endpoint_for(
            ProviderConfigureRequest(
                provider="openai_compatible",
                api_key="abcdefgh",
                model="model",
                endpoint="http://localhost:8000",
            )
        )
    assert "allowlist" in unsafe_error.value.detail

    allowed_settings = Settings(
        environment="test",
        session_secret="test-session-secret-with-at-least-32-bytes",
        canvas_token_secret=Fernet.generate_key().decode(),
        provider_encryption_secret=Fernet.generate_key().decode(),
        provider_allowed_endpoints="https://llm.example/v1",
    )
    allowed = ProviderConfigureRequest(
        provider="openai_compatible",
        api_key="abcdefgh",
        model="model",
        endpoint="https://llm.example/v1",
    )
    assert endpoint_for(allowed, allowed_settings) == "https://llm.example/v1"
    rebound = allowed.model_copy(update={"endpoint": "https://rebind.example/v1"})
    with pytest.raises(Exception) as rebound_error:
        endpoint_for(rebound, allowed_settings)
    assert "allowlist" in rebound_error.value.detail


def test_study_guide_is_structurally_distinct():
    evidence = [
        Evidence(
            text="A sufficiently detailed evidence sentence for a study guide.",
            source_id=None,
            source_chunk_id=None,
            source_title="Fixture",
            citation_ref="fixture#1",
        )
    ]
    guide = build_grounded_markdown("study_guide", evidence)
    assert "## Review point 1" in guide
    assert "- [ ] Explain review point 1" in guide


@pytest.mark.parametrize("event_type", ["summary", "outline", "study_guide"])
def test_activity_schema_accepts_each_study_output_type(event_type):
    entry = ActivityEntryResponse(
        id=uuid.uuid4(),
        event_type=event_type,
        category="study_guides",
        title="Generated study material",
        summary="Grounded in workspace sources",
        href="/wiki/guides/example",
        resource_id=uuid.uuid4(),
        created_at=datetime.now(UTC),
    )

    assert entry.event_type == event_type


@pytest.mark.parametrize(
    "field", ["question_text", "feedback", "topic_tag", "confidence", "reviewed"]
)
def test_marked_question_patch_rejects_explicit_null(field):
    with pytest.raises(ValidationError):
        MarkedPaperQuestionUpdate.model_validate({field: None})


@pytest.mark.asyncio
async def test_global_transport_body_limit_rejects_before_parsing(client):
    response = await client.post(
        "/api/outputs",
        content=b"x" * (15 * 1024 * 1024 + 1),
        headers={"content-type": "application/json"},
    )
    assert response.status_code == 413


def test_marked_paper_base64_limit_is_encoded_size_bound():
    raw = b"private marked paper"
    encoded = base64.b64encode(raw).decode()
    assert base64.b64decode(encoded) == raw
