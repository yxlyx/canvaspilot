const std = @import("std");

// src/lib/types.zig — Zig structs shared across frontend routes. The top
// section mirrors FastAPI Pydantic schemas; M2 prototype structs below model
// workspace sources, wiki pages, and flashcards while backend endpoints land.

pub const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    canvas_user_id: ?i64 = null,
};

pub const TokenResponse = struct {
    token: []const u8,
    user: User,
};

pub const Module = struct {
    id: []const u8,
    name: []const u8,
    code: []const u8,
    term: []const u8,
    last_synced_at: ?[]const u8 = null,
};

pub const Announcement = struct {
    id: []const u8,
    module_id: []const u8,
    title: []const u8,
    content: []const u8,
    posted_at: []const u8,
    summary: ?[]const u8 = null,
};

pub const Assignment = struct {
    id: []const u8,
    module_id: []const u8,
    title: []const u8,
    due_at: ?[]const u8,
    points_possible: ?f64,
};

pub const Task = struct {
    id: []const u8,
    module_id: []const u8,
    title: []const u8,
    task_type: []const u8,
    due_at: ?[]const u8,
    completed: bool,
    source_url: []const u8,
};

pub const Citation = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
    source_id: ?[]const u8 = null,
    citation_ref: ?[]const u8 = null,
    reference_number: ?usize = null,
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    citations: ?[]const Citation = null,
};

pub const ChatRequest = struct {
    module_id: ?[]const u8 = null,
    enrollment_id: ?[]const u8 = null,
    message: []const u8,
    history: []const ChatMessage = &.{},
};

pub const SyncStatus = struct {
    status: []const u8,
};

pub const WorkspaceSource = struct {
    id: []const u8,
    module_id: []const u8,
    title: []const u8,
    source_type: []const u8,
    status: []const u8,
    topics: []const []const u8,
    updated_at: []const u8,
    summary: []const u8,
    chunk_count: usize,
    url: []const u8 = "",
};

pub const CurriculumTopicResponse = struct {
    id: []const u8,
    position: usize,
    title: []const u8,
    archived: bool,
    state: []const u8,
    provenance: []const u8,
    extraction_rule: []const u8 = "",
    extraction_rule_hash: []const u8 = "",
    source_sha256: []const u8 = "",
};

pub const SourceResponse = struct {
    id: []const u8,
    user_id: []const u8,
    enrollment_id: ?[]const u8 = null,
    source_type: []const u8,
    origin: []const u8 = "",
    external_id: ?[]const u8 = null,
    title: []const u8,
    source_url: []const u8 = "",
    citation_label: []const u8 = "",
    topic_tags: []const []const u8 = &.{},
    status: []const u8,
    course_context: ?[]const u8 = null,
    project_context: ?[]const u8 = null,
    last_imported_at: ?[]const u8 = null,
    import_error: ?[]const u8 = null,
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const WikiCitationResponse = struct {
    id: []const u8,
    page_id: []const u8,
    source_id: []const u8,
    source_chunk_id: ?[]const u8 = null,
    citation_key: []const u8,
    citation_ref: []const u8,
    source_title: []const u8,
    location_label: []const u8 = "",
    chunk_index: ?i64 = null,
    snippet: []const u8 = "",
    created_at: []const u8 = "",
};

pub const WikiPageResponse = struct {
    id: []const u8,
    user_id: []const u8,
    slug: []const u8,
    title: []const u8,
    page_type: []const u8 = "source",
    markdown: []const u8,
    summary: []const u8 = "",
    source_ids: []const []const u8 = &.{},
    citation_count: usize = 0,
    backlinks: []const []const u8 = &.{},
    citations: []const WikiCitationResponse = &.{},
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const FlashcardResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    user_id: []const u8,
    source_id: ?[]const u8 = null,
    source_chunk_id: ?[]const u8 = null,
    wiki_page_id: ?[]const u8 = null,
    order_index: usize = 0,
    card_type: []const u8 = "short_answer",
    question: []const u8,
    answer: []const u8,
    topic_tag: []const u8 = "general",
    topic_ids: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    citation_ref: []const u8 = "",
    citations: []const std.json.Value = &.{},
    source_title: []const u8 = "",
    location_label: []const u8 = "",
    state: []const u8 = "active",
    manual_note: bool = false,
    approved: bool = false,
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const FlashcardRevisionResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    user_id: []const u8,
    revision: usize,
    action: []const u8,
    before: std.json.Value,
    after: std.json.Value,
    created_at: []const u8,
};

pub const FlashcardDeckResponse = struct {
    id: []const u8,
    user_id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    generation_scope: []const u8 = "sources",
    source_ids: []const []const u8 = &.{},
    wiki_page_id: ?[]const u8 = null,
    topic_tags: []const []const u8 = &.{},
    card_count: usize = 0,
    lifecycle: []const u8 = "draft",
    revision: usize = 1,
    input_fingerprint: ?[]const u8 = null,
    scope_snapshot: std.json.Value = .null,
    generator_snapshot: std.json.Value = .null,
    enrollment_id: ?[]const u8 = null,
    topic_ids: []const []const u8 = &.{},
    predecessor_id: ?[]const u8 = null,
    approved_at: ?[]const u8 = null,
    retired_at: ?[]const u8 = null,
    approved_snapshot: std.json.Value = .null,
    cards: []const FlashcardResponse = &.{},
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
};

pub const ProcessingStageResponse = struct {
    id: []const u8,
    name: []const u8,
    position: usize,
    status: []const u8,
    attempt_count: usize,
    max_attempts: usize,
    available_at: []const u8,
    started_at: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,
    outcome: std.json.Value = .null,
    error_code: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const ProcessingRunResponse = struct {
    id: []const u8,
    source_id: []const u8,
    source_version_id: []const u8,
    status: []const u8,
    current_stage: []const u8,
    attempt_count: usize,
    started_at: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,
    cancelled_at: ?[]const u8 = null,
    pause_reason: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    created_at: []const u8,
    updated_at: []const u8,
    stages: []const ProcessingStageResponse = &.{},
};

pub const ProcessingPolicyResponse = struct {
    process_sources: bool,
    map_topics: bool,
    compile_wiki: bool,
    flashcard_mode: []const u8,
    require_deck_review: bool,
    updated_at: []const u8,
};

pub const FlashcardAttemptResponse = struct {
    id: []const u8,
    user_id: []const u8,
    deck_id: []const u8,
    card_id: []const u8,
    answer_text: []const u8 = "",
    is_correct: bool,
    confidence: ?u8 = null,
    created_at: []const u8 = "",
};
pub const WikiPage = struct {
    id: []const u8,
    slug: []const u8,
    title: []const u8,
    summary: []const u8,
    markdown: []const u8,
    topics: []const []const u8,
    updated_at: []const u8,
    citations: []const Citation,
};

pub const FlashcardDeck = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    source_id: []const u8,
    topics: []const []const u8,
    card_count: usize,
    due_count: usize,
    updated_at: []const u8,
};

pub const Flashcard = struct {
    id: []const u8,
    deck_id: []const u8,
    question: []const u8,
    answer: []const u8,
    topic: []const u8,
    citation: Citation,
};

// Synthetic Milestone 3 demo-only presentation models. Live response models
// that mirror the backend contracts are declared below.
pub const ProviderStatus = enum { configured, disconnected, invalid, pending };

pub const ProviderCapability = struct {
    label: []const u8,
    available: bool,
};

pub const ProviderFieldKind = enum { text, url, secret };

pub const ProviderField = struct {
    id: []const u8,
    label: []const u8,
    placeholder: []const u8,
    kind: ProviderFieldKind,
    required: bool,
};

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    status: ProviderStatus,
    status_detail: []const u8,
    capabilities: []const ProviderCapability,
    fields: []const ProviderField,
};

pub const OutputBoundaryState = enum { grounded, insufficient_context, unavailable };

pub const OutputCitation = struct {
    id: []const u8,
    source_id: []const u8,
    source_title: []const u8,
    location: []const u8,
    snippet: []const u8,
};

pub const CitedOutput = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    boundary: OutputBoundaryState,
    citations: []const OutputCitation,
};

pub const HealthState = enum { healthy, warning, failed, stale, unknown };
pub const HealthSeverity = enum { info, warning, critical };

pub const HealthSummary = struct {
    healthy: usize,
    warning: usize,
    failed: usize,
    stale: usize,
    unknown: usize,
};

pub const HealthFinding = struct {
    id: []const u8,
    severity: HealthSeverity,
    state: HealthState,
    title: []const u8,
    detail: []const u8,
    subject: []const u8,
    recommendation: []const u8,
    action_label: []const u8,
    action_href: []const u8,
};

pub const DiffKind = enum { context, addition, deletion };

pub const DiffLine = struct {
    kind: DiffKind,
    text: []const u8,
};

pub const HistoryChange = struct {
    id: []const u8,
    change_type: []const u8,
    subject_id: []const u8,
    subject_title: []const u8,
    version_from: u32,
    version_to: u32,
    changed_at: []const u8,
    summary: []const u8,
    citation_change: []const u8,
    diff: []const DiffLine,
};

pub const KnowledgeSignal = struct {
    id: []const u8,
    label: []const u8,
    evidence: []const u8,
    trend: []const u8,
    observed_at: []const u8,
};

pub const KnowledgeMeter = struct {
    id: []const u8,
    topic: []const u8,
    estimate_percent: ?u8,
    confidence: []const u8,
    evidence_count: usize,
    recency: []const u8,
    trend: []const u8,
    signals: []const KnowledgeSignal,
};

pub const KnowledgeOverview = struct {
    estimate_percent: ?u8,
    confidence: []const u8,
    evidence_count: usize,
    recency: []const u8,
    known_topic_count: usize,
    unknown_topic_count: usize,
};

pub const KnowledgeAction = struct {
    label: []const u8,
    href: []const u8,
};

pub const KnowledgeRecommendation = struct {
    id: []const u8,
    topic_id: []const u8,
    title: []const u8,
    why: []const u8,
    evidence: []const u8,
    next_action: []const u8,
    actions: []const KnowledgeAction,
};

pub const EvidenceScore = struct {
    earned: ?f32,
    possible: ?f32,
};

pub const MarkedEvidence = struct {
    id: []const u8,
    question: []const u8,
    topic: []const u8,
    score: EvidenceScore,
    extraction_confidence: []const u8,
    feedback: []const u8,
    proposal: []const u8,
};

pub const MarkedPaper = struct {
    id: []const u8,
    title: []const u8,
    imported_at: []const u8,
    privacy_note: []const u8,
    score: EvidenceScore,
    extraction_confidence: []const u8,
    evidence: []const MarkedEvidence,
};

// Live Milestone 3 contracts mirror backend/app/schemas/m3.py. Unknown fields
// are ignored by the backend client, while required evidence fields fail closed.
pub const StudyOutputCitationResponse = struct {
    id: []const u8,
    source_id: []const u8,
    source_chunk_id: ?[]const u8 = null,
    citation_key: []const u8,
    citation_ref: []const u8,
    source_title: []const u8,
    snippet: []const u8,
};
pub const StudyOutputResponse = struct {
    id: []const u8,
    output_type: []const u8,
    title: []const u8,
    status: []const u8,
    content: []const u8,
    source_ids: []const []const u8,
    wiki_page_id: ?[]const u8,
    message: []const u8,
    citations: []const StudyOutputCitationResponse = &.{},
    created_at: []const u8,
    updated_at: []const u8,
};
pub const HealthFindingResponse = struct {
    id: []const u8,
    code: []const u8,
    severity: []const u8,
    state: []const u8,
    resource_type: []const u8,
    resource_id: ?[]const u8,
    topic: ?[]const u8 = null,
    message: []const u8,
    recommendation: []const u8,
    created_at: []const u8,
};
pub const HistoryEntryResponse = struct { id: []const u8, entry_type: []const u8, resource_id: []const u8, summary: []const u8, created_at: []const u8 };
pub const WikiRevisionResponse = struct { id: []const u8, page_id: []const u8, revision_number: usize, title: []const u8, markdown: []const u8, source_ids: []const []const u8, citation_count: usize, change_summary: []const u8, created_at: []const u8 };
pub const RevisionDiffResponse = struct { page_id: []const u8, from_revision: usize, to_revision: usize, diff: []const u8 };
pub const MeterSignalResponse = struct { name: []const u8, value: ?f64, evidence_count: usize };
pub const TopicMeterResponse = struct { topic: []const u8, estimated_completion: ?f64, evidence_confidence: ?f64, evidence_count: usize, state: []const u8, stale: bool, signals: []const MeterSignalResponse, recommendation: []const u8, reason_code: ?[]const u8 = null };
pub const MarkedPaperQuestionResponse = struct { id: []const u8, question_number: usize, question_text: []const u8, awarded_marks: ?f64, available_marks: ?f64, feedback: []const u8, topic_tag: []const u8, confidence: f64, reviewed: bool, reviewed_at: ?[]const u8 };
pub const MarkedPaperResponse = struct { id: []const u8, filename: []const u8, content_type: []const u8, extraction_status: []const u8, extraction_message: []const u8, questions: []const MarkedPaperQuestionResponse = &.{}, created_at: []const u8, updated_at: []const u8 };
pub const StudyOutputPageResponse = struct { items: []const StudyOutputResponse, next_cursor: ?[]const u8 };
pub const MarkedPaperPageResponse = struct { items: []const MarkedPaperResponse, next_cursor: ?[]const u8 };
pub const ProviderAuthMethodDescriptor = struct {
    kind: []const u8,
    label: []const u8,
    recommended: bool = false,
    enabled: bool = true,
    unavailable_reason: ?[]const u8 = null,
};
pub const ProviderDescriptor = struct {
    id: []const u8,
    name: []const u8,
    models: []const []const u8,
    endpoint: []const u8,
    description: []const u8 = "",
    capabilities: []const []const u8 = &.{},
    auth_methods: []const ProviderAuthMethodDescriptor = &.{},
    setup_url: []const u8 = "",
    billing_note: []const u8 = "",
    endpoint_mode: []const u8 = "fixed",
    supports_generation: bool = true,
    supports_embeddings: bool = false,
    recommended: bool = false,
    catalog_mode: []const u8 = "static",
    legacy: bool = false,
};
pub const ProviderAuthorizationSessionResponse = struct {
    id: []const u8,
    provider: []const u8,
    status: []const u8,
    expires_at: []const u8,
    error_code: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    verification_uri: ?[]const u8 = null,
    verification_uri_complete: ?[]const u8 = null,
    user_code: ?[]const u8 = null,
    poll_interval_seconds: ?usize = null,
};
pub const ProviderModelOption = struct { id: []const u8, label: []const u8 };
pub const ProviderStatusResponse = struct {
    provider: []const u8,
    model: []const u8,
    endpoint: []const u8,
    auth_method: []const u8 = "api_key",
    status: []const u8,
    active_for_generation: bool = false,
    provider_account_label: ?[]const u8 = null,
    access_token_expires_at: ?[]const u8 = null,
    last_error_code: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    credential: []const u8 = "********",
    last_tested_at: ?[]const u8,
    last_refreshed_at: ?[]const u8 = null,
    updated_at: []const u8,
};
pub const UserPreferenceResponse = struct {
    theme: []const u8,
    motion_preference: []const u8,
    default_module_id: ?[]const u8,
    default_enrollment_id: ?[]const u8,
    daily_review_target: usize,
    reminder_daily_review: bool,
    reminder_processing_attention: bool,
    reminder_paper_review: bool,
    reminder_health_attention: bool,
    updated_at: []const u8,
};
pub const NotificationResponse = struct {
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    body: []const u8,
    href: []const u8,
    created_at: []const u8,
    read_at: ?[]const u8,
};
pub const NotificationPageResponse = struct {
    items: []const NotificationResponse,
    unread_count: usize,
};
pub const NotificationCountResponse = struct { unread_count: usize };
pub const EnrollmentResponse = struct {
    id: []const u8,
    code: []const u8,
    title: []const u8,
    academic_year: []const u8,
    semester: u8,
    provenance: []const u8,
    import_method: []const u8,
    topic_state: []const u8,
    evidence_warning: ?[]const u8,
    archived: bool,
    institution: []const u8,
    provider: []const u8,
    provider_version: []const u8,
    provider_academic_year: []const u8,
    source_url: []const u8,
    provider_fetched_at: []const u8,
    payload_sha256: []const u8,
};

pub const ActivityEntryResponse = struct {
    id: []const u8,
    event_type: []const u8,
    category: []const u8,
    title: []const u8,
    summary: []const u8,
    href: []const u8,
    resource_id: ?[]const u8,
    created_at: []const u8,
    revision_number: ?usize = null,
};
