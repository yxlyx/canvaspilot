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
