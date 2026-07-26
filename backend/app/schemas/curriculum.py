import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

MODULE_CODE_PATTERN = r"^[A-Z0-9]{2,16}$"
ACADEMIC_YEAR_PATTERN = r"^\d{4}-\d{4}$"


class ImportPreviewRequest(BaseModel):
    academic_year: str = Field(pattern=ACADEMIC_YEAR_PATTERN)
    share_url: str | None = Field(default=None, min_length=1, max_length=8192)
    module_codes: list[str] = Field(default_factory=list, max_length=30)
    semester: int | None = Field(default=None, ge=1, le=4)

    @field_validator("academic_year")
    @classmethod
    def canonical_academic_year(cls, value: str) -> str:
        start, end = map(int, value.split("-"))
        if end != start + 1 or not 2000 <= start <= 2100:
            raise ValueError("academic year must be consecutive years in YYYY-YYYY form")
        return value

    @field_validator("module_codes")
    @classmethod
    def normalize_codes(cls, values: list[str]) -> list[str]:
        normalized = []
        for value in values:
            code = value.strip().upper()
            if not code or len(code) > 16 or not code.isalnum():
                raise ValueError("invalid module code")
            if code not in normalized:
                normalized.append(code)
        return normalized

    @model_validator(mode="after")
    def validate_input(self):
        if bool(self.share_url) == bool(self.module_codes):
            raise ValueError("provide exactly one of share_url or module_codes")
        if self.module_codes and self.semester is None:
            raise ValueError("semester is required with manual module codes")
        return self


class ImportPreviewItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    code: str
    title: str
    available: bool
    disposition: Literal["import", "already_enrolled", "restore", "unavailable", "not_found"]
    lesson_config: dict[str, str | list[str]]
    provider_version: str | None
    source_url: str | None
    fetched_at: datetime | None
    payload_sha256: str | None


class ImportReconciliation(BaseModel):
    added: list[str]
    unchanged: list[str]
    removed: list[str]
    ambiguous: list[str]


class ImportPreviewResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    academic_year: str
    semester: int
    import_method: Literal["share_url", "manual_codes"]
    expires_at: datetime
    reconciliation: ImportReconciliation
    items: list[ImportPreviewItemResponse]


class ImportCommitRequest(BaseModel):
    selected_codes: list[str] = Field(default_factory=list, max_length=30)
    archive_codes: list[str] = Field(default_factory=list, max_length=30)

    @field_validator("selected_codes", "archive_codes")
    @classmethod
    def canonical_unique_codes(cls, values: list[str]) -> list[str]:
        normalized = [value.strip().upper() for value in values]
        if any(not code or len(code) > 16 or not code.isalnum() for code in normalized) or len(
            normalized
        ) != len(set(normalized)):
            raise ValueError("module codes must be canonical and unique")
        return normalized

    @model_validator(mode="after")
    def disjoint_decisions(self):
        if set(self.selected_codes) & set(self.archive_codes):
            raise ValueError("a module cannot be selected and archived")
        if len(self.selected_codes) + len(self.archive_codes) > 30:
            raise ValueError("at most 30 module decisions are allowed")
        return self


class ImportCommitResponseItem(BaseModel):
    code: str
    status: Literal[
        "imported",
        "restored",
        "already_enrolled",
        "archived",
        "unavailable",
        "not_found",
        "failed",
    ]
    enrollment_id: uuid.UUID | None = None
    warning: str | None = None


class ImportCommitResponse(BaseModel):
    preview_id: uuid.UUID
    items: list[ImportCommitResponseItem]


class EnrollmentResponse(BaseModel):
    id: uuid.UUID
    code: str
    title: str
    academic_year: str
    semester: int
    provenance: str
    import_method: str
    topic_state: str
    evidence_warning: str | None
    lesson_config: dict
    archived: bool
    institution: str
    provider: str
    provider_version: str
    provider_academic_year: str
    source_url: str
    provider_fetched_at: datetime
    payload_sha256: str


class TopicResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    position: int
    title: str
    archived: bool
    state: Literal["provisional", "canonical"]
    provenance: str
    extraction_rule: str
    extraction_rule_hash: str
    source_sha256: str


class ReviewedTopic(BaseModel):
    id: uuid.UUID | None = None
    title: str = Field(min_length=1, max_length=300)
    archived: bool = False

    @field_validator("title")
    @classmethod
    def strip_title(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("topic title cannot be blank")
        return value


class TopicListUpdate(BaseModel):
    topics: list[ReviewedTopic] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def unique_ids(self):
        ids = [topic.id for topic in self.topics if topic.id]
        if len(ids) != len(set(ids)):
            raise ValueError("topic IDs must be unique")
        return self


class SyllabusRefinementRequest(BaseModel):
    source_id: uuid.UUID


class TopicRevisionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    enrollment_id: uuid.UUID
    source_id: uuid.UUID | None
    status: Literal["pending", "accepted", "rejected"]
    base_topics: list[dict]
    proposed_topics: list[dict]
    mapping: dict
    algorithm: str
    created_at: datetime
    reviewed_at: datetime | None


class TopicRevisionDecision(BaseModel):
    decision: Literal["accept", "reject"]


class ProposalGenerationRequest(BaseModel):
    source_ids: list[uuid.UUID] = Field(default_factory=list, max_length=100)

    @field_validator("source_ids")
    @classmethod
    def unique_sources(cls, values: list[uuid.UUID]) -> list[uuid.UUID]:
        if len(values) != len(set(values)):
            raise ValueError("source IDs must be unique")
        return values


class ManualAssociationRequest(BaseModel):
    topic_id: uuid.UUID
    source_id: uuid.UUID
    chunk_ids: list[uuid.UUID] = Field(min_length=1, max_length=20)
    reason_code: str = Field(default="manual_source_review", min_length=1, max_length=64)

    @field_validator("chunk_ids")
    @classmethod
    def unique_chunks(cls, values: list[uuid.UUID]) -> list[uuid.UUID]:
        if len(values) != len(set(values)):
            raise ValueError("chunk IDs must be unique")
        return values


class AssociationDecisionRequest(BaseModel):
    decision: Literal["confirm", "reject"]


class AssociationEvidenceResponse(BaseModel):
    chunk_id: uuid.UUID
    citation: str
    excerpt: str
    location: str


class TopicSourceAssociationResponse(BaseModel):
    id: uuid.UUID
    topic_id: uuid.UUID
    source_id: uuid.UUID
    source_title: str
    source_status: str
    status: Literal["proposed", "confirmed", "rejected"]
    method: Literal["deterministic", "manual"]
    evidence_strength: float
    algorithm: str
    rule_hash: str
    source_fingerprint: str
    topic_fingerprint: str
    evidence: list[AssociationEvidenceResponse]
    reason_code: str
    stale: bool
    stale_reason: str | None
    created_at: datetime
    reviewed_at: datetime | None
    reviewer_id: uuid.UUID | None


class CoverageGuidance(BaseModel):
    recommended_source_kinds: list[str]
    source_intake_url: str


class TopicCoverageResponse(BaseModel):
    topic_id: uuid.UUID
    position: int
    title: str
    state: Literal["covered", "review", "missing"]
    confirmed_sources: list[TopicSourceAssociationResponse]
    proposed_sources: list[TopicSourceAssociationResponse]
    reason_codes: list[str]
    guidance: CoverageGuidance


class CoverageDashboardResponse(BaseModel):
    enrollment_id: uuid.UUID
    disclosure: Literal["source_coverage_not_mastery"]
    numerator: int
    denominator: int
    percentage: float | None
    provisional: bool
    warning: str | None
    topics: list[TopicCoverageResponse]


class LearningMetricEvidenceLink(BaseModel):
    association_id: uuid.UUID
    source_id: uuid.UUID
    source_title: str
    status: Literal["confirmed", "proposed"]
    stale: bool
    stale_reason: str | None
    evidence: list[AssociationEvidenceResponse]


class SourceCoverageTopicMetric(BaseModel):
    topic_id: uuid.UUID
    position: int
    title: str
    state: Literal["covered", "missing", "review", "stale"]
    reason_codes: list[str]
    evidence_links: list[LearningMetricEvidenceLink]


class SourceCoverageMetric(BaseModel):
    authoritative: bool
    numerator: int
    denominator: int | None
    percentage: float | None
    reason_code: str | None
    warning: str | None
    covered_topics: list[SourceCoverageTopicMetric]
    missing_topics: list[SourceCoverageTopicMetric]
    review_topics: list[SourceCoverageTopicMetric]
    stale_topics: list[SourceCoverageTopicMetric]


class RecallTopicMetric(BaseModel):
    topic_id: uuid.UUID
    position: int
    title: str
    correct_attempts: int
    attempt_count: int
    percentage: float | None
    last_evidence_at: datetime | None
    reason_code: str | None
    warning: str | None


class RecallMetric(BaseModel):
    correct_attempts: int
    attempt_count: int
    percentage: float | None
    last_evidence_at: datetime | None
    reason_code: str | None
    warning: str | None
    topics: list[RecallTopicMetric]


class ActivityVolumeMetric(BaseModel):
    attempt_count: int
    cards_reviewed: int
    session_count: int | None
    source_uploads: int
    source_changes: int


class LearningMetricsMethodology(BaseModel):
    coverage_formula: str
    recall_formula: str
    activity_formula: str
    window_start: datetime
    window_end: datetime
    rolling_window_days: int
    minimum_attempts_per_topic: int
    minimum_attempts_overall: int
    freshness_cutoff: datetime
    rating_semantics: dict[str, bool]
    exclusions: list[str]
    disclosures: list[Literal["source_coverage_not_mastery", "self_reported_recall_not_mastery"]]


class EnrollmentLearningMetricsResponse(BaseModel):
    enrollment_id: uuid.UUID
    source_coverage: SourceCoverageMetric
    recall: RecallMetric
    activity: ActivityVolumeMetric
    methodology: LearningMetricsMethodology


class ProposalGenerationResponse(BaseModel):
    created: int
    updated: int
    unchanged: int
    protected_decisions: int
    associations: list[TopicSourceAssociationResponse]


class CandidateSourceResponse(BaseModel):
    id: uuid.UUID
    title: str
    source_type: str
    state: Literal["ready", "processing", "failed"]
    import_error: str | None
    attachment: Literal["enrollment", "unscoped", "other_enrollment"]
    eligible: bool


class CandidateSourceChunkResponse(BaseModel):
    chunk_id: uuid.UUID
    citation: str
    location: str
    excerpt: str = Field(max_length=322)
    relevance: float = Field(ge=0, le=1)
    rank: int = Field(ge=1, le=100)
