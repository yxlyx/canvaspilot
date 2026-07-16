// src/lib/mock.zig — stable fixture data for offline milestone demos. M1 uses
// the module, announcements, and tasks; M2 adds source, wiki, and flashcard
// records so the frontend can stay usable while backend endpoints land.

const types = @import("types.zig");

pub const me: types.User = .{
    .id = "00000000-0000-0000-0000-000000000001",
    .name = "Lim Yu Xi",
    .email = "yuxi@u.nus.edu",
    .canvas_user_id = null,
};

pub const demo_module: types.Module = .{
    .id = "11111111-1111-1111-1111-111111111111",
    .name = "Programming Methodology II",
    .code = "CS2030S",
    .term = "AY25/26 S1",
    .last_synced_at = "2026-05-12T09:30:00Z",
};

/// All mock modules. The fixture stays single-module for deterministic demos,
/// but the workspace views aggregate richer source/wiki/flashcard records.
pub const modules: []const types.Module = &.{demo_module};

pub const announcements: []const types.Announcement = &.{
    .{
        .id = "ann-1",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 6 deadline extended to Friday 23:59",
        .content = "Hi all — based on feedback we've extended Lab 6 by 48 hours.",
        .posted_at = "2026-05-12T08:15:00Z",
        .summary = "Lab 6 due Fri 23:59. New testcases on Coursemology.",
    },
    .{
        .id = "ann-2",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lecture 9 slides + recording posted",
        .content = "Slides for lecture 9 (immutable lists, lazy streams) are up.",
        .posted_at = "2026-05-10T16:42:00Z",
        .summary = "Lecture 9: immutable lists, lazy streams.",
    },
};

pub const tasks: []const types.Task = &.{
    .{
        .id = "task-1",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 6: Functional collections",
        .task_type = "assignment",
        .due_at = "2026-05-15T15:59:00Z",
        .completed = false,
        .source_url = "https://canvas.nus.edu.sg/courses/1/assignments/61",
    },
    .{
        .id = "task-2",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 7: Streams",
        .task_type = "assignment",
        .due_at = "2026-05-22T15:59:00Z",
        .completed = false,
        .source_url = "https://canvas.nus.edu.sg/courses/1/assignments/62",
    },
};

pub const sources: []const types.WorkspaceSource = &.{
    .{
        .id = "src-lecture-9",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lecture 9: Immutable Lists and Lazy Streams",
        .source_type = "markdown",
        .status = "indexed",
        .topics = &.{ "immutability", "streams", "higher-order functions" },
        .updated_at = "2026-05-18T10:20:00Z",
        .summary = "Lecture notes imported from the CS2030S source set and chunked for cited Q&A.",
        .chunk_count = 8,
        .url = "/wiki/immutable-lists",
    },
    .{
        .id = "src-lab-6",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 6: Functional Collections Brief",
        .source_type = "assignment",
        .status = "indexed",
        .topics = &.{ "functional collections", "map/filter/reduce" },
        .updated_at = "2026-05-17T14:00:00Z",
        .summary = "Assignment brief, due-date note, and test-case guidance for Lab 6.",
        .chunk_count = 5,
        .url = "https://canvas.nus.edu.sg/courses/1/assignments/61",
    },
    .{
        .id = "src-ann-2",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lecture 9 slides + recording posted",
        .source_type = "announcement",
        .status = "needs review",
        .topics = &.{ "lecture logistics", "streams" },
        .updated_at = "2026-05-10T16:42:00Z",
        .summary = "Announcement linking the slides and recording used by the generated wiki page.",
        .chunk_count = 2,
        .url = "/wiki/immutable-lists",
    },
    .{
        .id = "src-lab-7",
        .module_id = "11111111-1111-1111-1111-111111111111",
        .title = "Lab 7: Streams Draft Import",
        .source_type = "assignment",
        .status = "processing",
        .topics = &.{ "lazy streams", "recursion" },
        .updated_at = "2026-05-22T15:59:00Z",
        .summary = "Queued source import showing the loading-state copy used while backend jobs run.",
        .chunk_count = 0,
        .url = "https://canvas.nus.edu.sg/courses/1/assignments/62",
    },
};

pub const wiki_pages: []const types.WikiPage = &.{
    .{
        .id = "wiki-immutable-lists",
        .slug = "immutable-lists",
        .title = "Immutable Lists and Lazy Streams",
        .summary = "How persistent lists and delayed evaluation work together in CS2030S.",
        .markdown = "# Immutable lists and lazy streams\n\nImmutable lists avoid in-place updates. Operations such as map and filter return new list values, which keeps previous versions available for reasoning and testing.\n\nLazy streams defer computation until a value is requested. This makes it possible to describe large or infinite sequences while only evaluating the prefix that a program needs.\n\nIn Lab 6, the practical pattern is to keep transformations pure, then compose them into a pipeline that is easy to cite and debug.",
        .topics = &.{ "immutability", "streams", "functional collections" },
        .updated_at = "2026-05-18T10:30:00Z",
        .citations = &.{
            .{
                .title = "Lecture 9: Immutable Lists and Lazy Streams",
                .url = "/sources?type=markdown",
                .snippet = "Slides for lecture 9 cover immutable lists and lazy streams.",
            },
            .{
                .title = "Lab 6: Functional Collections Brief",
                .url = "/sources?type=assignment",
                .snippet = "Lab 6 asks students to compose functional collection operations.",
            },
        },
    },
    .{
        .id = "wiki-lab-6",
        .slug = "lab-6-functional-collections",
        .title = "Lab 6 Functional Collections Checklist",
        .summary = "A cited checklist for completing and reviewing the Lab 6 submission.",
        .markdown = "# Lab 6 Functional Collections Checklist\n\nStart by confirming the updated Friday 23:59 deadline. Then review the new Coursemology test cases before final submission.\n\nFor each collection operation, note the input type, output type, and whether the transformation is pure. This reduces mistakes when chaining map, filter, and reduce.",
        .topics = &.{ "functional collections", "deadlines" },
        .updated_at = "2026-05-17T16:10:00Z",
        .citations = &.{
            .{
                .title = "Lab 6 deadline extended to Friday 23:59",
                .url = "/sources?type=announcement",
                .snippet = "Lab 6 due Fri 23:59. New testcases on Coursemology.",
            },
        },
    },
};

pub const decks: []const types.FlashcardDeck = &.{
    .{
        .id = "deck-streams",
        .title = "CS2030S Streams Primer",
        .description = "Concept checks generated from the Lecture 9 wiki page.",
        .source_id = "wiki-immutable-lists",
        .topics = &.{ "immutability", "streams" },
        .card_count = 3,
        .due_count = 2,
        .updated_at = "2026-05-18T11:00:00Z",
    },
    .{
        .id = "deck-lab-6",
        .title = "Lab 6 Review",
        .description = "Short-answer prompts tied to the assignment brief and announcement.",
        .source_id = "wiki-lab-6",
        .topics = &.{ "functional collections", "deadlines" },
        .card_count = 2,
        .due_count = 1,
        .updated_at = "2026-05-17T16:30:00Z",
    },
};

pub const flashcards: []const types.Flashcard = &.{
    .{
        .id = "card-streams-1",
        .deck_id = "deck-streams",
        .question = "Why are immutable lists easier to reason about than mutable lists?",
        .answer = "They avoid in-place updates, so earlier versions remain unchanged and transformations can be tested as pure values.",
        .topic = "immutability",
        .citation = .{
            .title = "Immutable Lists and Lazy Streams",
            .url = "/wiki/immutable-lists",
            .snippet = "Immutable lists avoid in-place updates and keep previous versions available.",
        },
    },
    .{
        .id = "card-streams-2",
        .deck_id = "deck-streams",
        .question = "What does lazy evaluation defer in a stream pipeline?",
        .answer = "It delays computing stream values until a consumer asks for them.",
        .topic = "streams",
        .citation = .{
            .title = "Immutable Lists and Lazy Streams",
            .url = "/wiki/immutable-lists",
            .snippet = "Lazy streams defer computation until a value is requested.",
        },
    },
    .{
        .id = "card-streams-3",
        .deck_id = "deck-streams",
        .question = "Which Lab 6 practice helps debug map/filter/reduce chains?",
        .answer = "Record each operation's input type, output type, and purity before chaining it.",
        .topic = "functional collections",
        .citation = .{
            .title = "Lab 6 Functional Collections Checklist",
            .url = "/wiki/lab-6-functional-collections",
            .snippet = "Note the input type, output type, and whether the transformation is pure.",
        },
    },
    .{
        .id = "card-lab-6-1",
        .deck_id = "deck-lab-6",
        .question = "What is the updated Lab 6 deadline?",
        .answer = "Friday at 23:59.",
        .topic = "deadlines",
        .citation = .{
            .title = "Lab 6 deadline extended to Friday 23:59",
            .url = "/sources?type=announcement",
            .snippet = "Lab 6 due Fri 23:59.",
        },
    },
    .{
        .id = "card-lab-6-2",
        .deck_id = "deck-lab-6",
        .question = "What should be checked before submitting Lab 6?",
        .answer = "Review the new Coursemology test cases before final submission.",
        .topic = "functional collections",
        .citation = .{
            .title = "Lab 6 Functional Collections Checklist",
            .url = "/wiki/lab-6-functional-collections",
            .snippet = "Review the new Coursemology test cases before final submission.",
        },
    },
};

pub const providers: []const types.Provider = &.{
    .{ .id = "demo-provider-openai", .name = "OpenAI", .status = .configured, .status_detail = "Configured for the demo; no credential is stored in this fixture.", .capabilities = &.{ .{ .label = "Cited summaries", .available = true }, .{ .label = "Embeddings", .available = true } } },
    .{ .id = "demo-provider-compatible", .name = "OpenAI-compatible", .status = .disconnected, .status_detail = "No endpoint connected.", .capabilities = &.{.{ .label = "Custom base URL", .available = true }} },
    .{ .id = "demo-provider-azure", .name = "Azure OpenAI", .status = .invalid, .status_detail = "Demo validation failed; reconnect when backend support lands.", .capabilities = &.{.{ .label = "Deployment selection", .available = true }} },
    .{ .id = "demo-provider-gemini", .name = "Gemini", .status = .pending, .status_detail = "Connection check is pending in this synthetic example.", .capabilities = &.{.{ .label = "Cited summaries", .available = true }} },
};

pub const output: types.CitedOutput = .{
    .id = "demo-output-streams-summary",
    .title = "Immutable lists and streams — cited summary",
    .summary = "Immutable lists preserve earlier values, while lazy streams evaluate only the values a consumer requests. Together they support traceable, composable transformations.",
    .boundary = .grounded,
    .citations = &.{
        .{ .id = "demo-citation-lecture", .source_id = "demo-source-lecture", .source_title = "Synthetic lecture notes", .location = "Section 2", .snippet = "Immutable operations return a new value instead of changing the existing list." },
        .{ .id = "demo-citation-lab", .source_id = "demo-source-lab", .source_title = "Synthetic lab brief", .location = "Exercise 4", .snippet = "A stream computes its next element only when requested." },
    },
};

pub const health_summary: types.HealthSummary = .{ .healthy = 2, .warning = 1, .failed = 1, .stale = 1, .unknown = 1 };
pub const health_findings: []const types.HealthFinding = &.{
    .{ .id = "demo-health-healthy", .severity = .info, .state = .healthy, .title = "Citation coverage healthy", .detail = "Every claim in the selected page has a source reference.", .subject = "Immutable lists", .recommendation = "No action needed." },
    .{ .id = "demo-health-warning", .severity = .warning, .state = .warning, .title = "Thin topic coverage", .detail = "Only one synthetic source supports recursion.", .subject = "Recursion", .recommendation = "Add a second source before generating a summary." },
    .{ .id = "demo-health-failed", .severity = .critical, .state = .failed, .title = "Broken source reference", .detail = "A fixture link has no indexed target.", .subject = "Lab checklist", .recommendation = "Review or remove the reference." },
    .{ .id = "demo-health-stale", .severity = .warning, .state = .stale, .title = "Page may be stale", .detail = "The source changed after the page version.", .subject = "Streams", .recommendation = "Regenerate after comparing history." },
    .{ .id = "demo-health-unknown", .severity = .info, .state = .unknown, .title = "File status unknown", .detail = "No check result exists for this synthetic item.", .subject = "Practice appendix", .recommendation = "Run checks when backend support is available." },
};

pub const history_changes: []const types.HistoryChange = &.{
    .{
        .id = "demo-history-streams-v3",
        .change_type = "content",
        .subject_id = "demo-wiki-streams",
        .subject_title = "Immutable lists and streams",
        .version_from = 2,
        .version_to = 3,
        .changed_at = "2026-05-19T09:00:00Z",
        .summary = "Clarified lazy evaluation and added one citation.",
        .citation_change = "+1 citation (2 → 3)",
        .diff = &.{ .{ .kind = .context, .text = "@@ -8,2 +8,2 @@" }, .{ .kind = .deletion, .text = "- Streams calculate all values immediately." }, .{ .kind = .addition, .text = "+ Streams calculate values when a consumer requests them." } },
    },
    .{
        .id = "demo-history-lab-v2",
        .change_type = "citations",
        .subject_id = "demo-wiki-lab",
        .subject_title = "Functional collections checklist",
        .version_from = 1,
        .version_to = 2,
        .changed_at = "2026-05-18T14:30:00Z",
        .summary = "Linked the deadline announcement to the checklist.",
        .citation_change = "+1 citation (1 → 2)",
        .diff = &.{ .{ .kind = .context, .text = "@@ Citations @@" }, .{ .kind = .addition, .text = "+ Lab 6 deadline announcement" } },
    },
};

pub const knowledge_meters: []const types.KnowledgeMeter = &.{
    .{ .id = "demo-meter-immutability", .topic = "Immutability", .estimate_percent = 78, .confidence = "medium", .evidence_count = 6, .recency = "2 days ago", .trend = "improving", .signals = &.{.{ .id = "demo-signal-cards", .label = "Flashcard practice", .evidence = "4 of 5 recent prompts correct", .trend = "up", .observed_at = "2026-05-18" }} },
    .{ .id = "demo-meter-recursion", .topic = "Recursion", .estimate_percent = null, .confidence = "insufficient evidence", .evidence_count = 1, .recency = "12 days ago", .trend = "unknown", .signals = &.{.{ .id = "demo-signal-recursion", .label = "Single answer", .evidence = "One observation cannot support an estimate", .trend = "unknown", .observed_at = "2026-05-08" }} },
};
pub const recommendations: []const types.KnowledgeRecommendation = &.{.{ .id = "demo-recommendation-recursion", .topic_id = "demo-meter-recursion", .title = "Collect more recursion evidence", .why = "The topic has only one old observation.", .evidence = "1 answer, last observed 12 days ago", .next_action = "Review two cited cards and record confidence." }};

pub const marked_papers: []const types.MarkedPaper = &.{
    .{ .id = "demo-paper-functional-midterm", .title = "Synthetic functional programming practice paper", .imported_at = "2026-05-16", .privacy_note = "Synthetic demo only. Real marked papers may contain sensitive educational data and must remain account-scoped.", .score = .{ .earned = 17, .possible = 25 }, .extraction_confidence = "medium", .evidence = &.{
        .{ .id = "demo-evidence-q1", .question = "Question 1: immutable list transformations", .topic = "Immutability", .score = .{ .earned = 7, .possible = 8 }, .extraction_confidence = "high", .feedback = "The synthetic marking note rewards pure transformations.", .proposal = "Proposed evidence: strong understanding of immutable transformations." },
        .{ .id = "demo-evidence-q2", .question = "Question 2: recursive stream construction", .topic = "Recursion", .score = .{ .earned = null, .possible = null }, .extraction_confidence = "low", .feedback = "The score could not be read reliably.", .proposal = "Proposed evidence only: review recursion before using this signal." },
    } },
    .{ .id = "demo-paper-unknown-score", .title = "Synthetic annotated worksheet", .imported_at = "2026-05-14", .privacy_note = "Synthetic demo only; no uploaded document exists.", .score = .{ .earned = null, .possible = null }, .extraction_confidence = "low", .evidence = &.{} },
};
