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
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    citations: ?[]const Citation = null,
};

pub const ChatRequest = struct {
    module_id: ?[]const u8 = null,
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

pub const SourceResponse = struct {
    id: []const u8,
    user_id: []const u8,
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
    citation_ref: []const u8 = "",
    source_title: []const u8 = "",
    location_label: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
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
    cards: []const FlashcardResponse = &.{},
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
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
