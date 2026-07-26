// api/chat.zig — Milestone 1 chat proxy.
//
// Proposal M1 1c: "user can ask a question, system retrieves relevant chunks
// via cosine similarity and returns a grounded response with source links".
//
// The browser POSTs a message, optional local enrollment scope, and history here.
// We re-serialize the body and forward it to FastAPI /api/chat with the user's bearer token
// (read from the HttpOnly cp_session cookie — never exposed to the browser),
// then read the Server-Sent Events response, aggregate the streamed tokens
// and citations, and return a single JSON {message, citations, grounded}
// reply.
//
// This is server-side aggregation rather than a streaming pass-through.
// The proposal only requires "returns a grounded response with source links",
// not token-by-token streaming — that's Milestone 2 polish.
//
// Only explicit demo requests use a canned reply. Live requests never fall
// back to plausible fixture content.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const log = std.log.scoped(.chat_api);

const ChatBody = struct {
    message: []const u8 = "",
    module_id: ?[]const u8 = null,
    enrollment_id: ?[]const u8 = null,
    history: []const lib.types.ChatMessage = &.{},
};

const ChatReply = lib.chat.Reply;

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) {
        return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    }
    if (req.body.len == 0) {
        return mer.badRequest("expected JSON body");
    }
    if (req.body.len > 128 * 1024) {
        return mer.badRequest("chat request is too large");
    }

    const parsed = std.json.parseFromSlice(ChatBody, req.allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        log.warn("chat: bad json body: {s}", .{@errorName(e)});
        return mer.badRequest("invalid JSON");
    };
    const body = parsed.value;

    if (body.message.len == 0) {
        return mer.badRequest("empty message");
    }
    if (body.message.len > 8000 or body.history.len > 40 or
        (body.module_id != null and body.module_id.?.len > 256) or
        (body.enrollment_id != null and body.enrollment_id.?.len > 256))
    {
        return mer.badRequest("chat request is too large");
    }
    if (body.module_id != null and body.enrollment_id != null) return mer.badRequest("choose one chat scope");
    for (body.history) |entry| {
        if (entry.content.len > 8000) return mer.badRequest("chat history entry is too large");
    }

    if (lib.m3.isExplicitDemo(req)) {
        return mockReply(req.allocator, body.message, true);
    }

    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) {
        return .{
            .status = .unauthorized,
            .content_type = .json,
            .body = "{\"error\":\"authentication required\"}",
        };
    }

    // Forward to FastAPI; aggregate SSE frames into a single reply.
    if (callBackend(req.allocator, session.token, body)) |reply| {
        return mer.typedJson(req.allocator, reply);
    } else |e| {
        log.warn("chat: authenticated backend error: {s}", .{@errorName(e)});
        return .{
            .status = .bad_gateway,
            .content_type = .json,
            .body = "{\"error\":\"live chat is unavailable; no demo answer was substituted\"}",
        };
    }
}

// ── Backend call ────────────────────────────────────────────────────────────

const BackendError = error{
    BackendUnreachable,
    BackendBadStatus,
    SerializeFailed,
    AuthFailed,
};

fn callBackend(
    allocator: std.mem.Allocator,
    token: []const u8,
    body: ChatBody,
) !ChatReply {
    const cfg = lib.config.load();
    const url = std.fmt.allocPrint(allocator, "{s}/api/chat", .{cfg.backend_url}) catch
        return error.SerializeFailed;
    const bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch
        return error.SerializeFailed;

    // Re-serialize the body so we control the schema sent to FastAPI.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    jw.write(body) catch return error.SerializeFailed;
    const send_body = out.written();

    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = bearer },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "text/event-stream" },
    };

    const res = mer.fetch(allocator, .{
        .url = url,
        .method = .POST,
        .body = send_body,
        .headers = &headers,
        .max_response_bytes = 512 * 1024,
    }) catch return error.BackendUnreachable;
    defer res.deinit(allocator);

    const status_int: u16 = @intFromEnum(res.status);
    if (status_int == 401 or status_int == 403) return error.AuthFailed;
    if (status_int >= 400) {
        log.warn("chat: backend returned HTTP {d}", .{status_int});
        return error.BackendBadStatus;
    }

    return try lib.chat.aggregateSse(allocator, res.body);
}

// ── SSE aggregator ──────────────────────────────────────────────────────────
//
// The backend emits frames like:
//
//   event: token
//   data: {"text": "Hello "}
//
//   event: citations
//   data: {"citations": [{...}]}
//
//   event: done
//   data: {"grounded": true, "confidence": 0.78, "message": "..."}
//
// We concatenate `token.text` into the reply message, collect the
// citations frame (if any), and read `grounded`/`confidence` from `done`.
// `done` may also carry a `message` field for the no-results path. The shared
// parser lives in lib.chat so the root test suite can cover real CRLF frames.

// ── Mock fallback ───────────────────────────────────────────────────────────

fn mockReply(allocator: std.mem.Allocator, question: []const u8, explicit_demo: bool) mer.Response {
    const safe_q = lib.ui.escapeSafe(allocator, question);

    if (isBalancedSearchTreeQuestion(question)) {
        const message = std.fmt.allocPrint(
            allocator,
            "(demo) Based on the generated wiki for \"{s}\": an AVL tree keeps every node's balance factor in {{-1, 0, 1}}. After an update, a single rotation repairs a left-left or right-right imbalance, while a double rotation repairs a left-right or right-left imbalance. These local pointer changes preserve the binary-search-tree order because the in-order key sequence does not change, and restoring the height invariant keeps search logarithmic.",
            .{safe_q},
        ) catch "(demo reply unavailable)";
        const citations = [_]lib.types.Citation{
            .{
                .title = "Balanced search trees",
                .url = if (explicit_demo) "/wiki/balanced-search-trees?mock=1" else "/wiki/balanced-search-trees",
                .snippet = "AVL rotations restore balance while preserving the in-order sequence of keys.",
            },
            .{
                .title = "Lecture 08 — Balanced Search Trees",
                .url = if (explicit_demo) "/sources?mock=1" else "/sources",
                .snippet = "The AVL invariant bounds each node's subtree-height difference; local rotations restore it after updates.",
            },
        };
        const reply: ChatReply = .{
            .message = message,
            .citations = &citations,
            .grounded = true,
            .confidence = 0.0,
            .source = "mock",
        };
        return mer.typedJson(allocator, reply);
    }

    if (containsAnyIgnoreCase(question, &.{ "stream", "lazy", "immutable", "list" })) {
        const message = std.fmt.allocPrint(
            allocator,
            "(demo) Based on the generated wiki for \"{s}\": immutable lists avoid in-place updates, while lazy streams defer work until a value is requested. This lets students describe large or infinite sequences but only evaluate the prefix needed by the program.",
            .{safe_q},
        ) catch "(demo reply unavailable)";
        const citations = [_]lib.types.Citation{
            .{
                .title = "Immutable Lists and Lazy Streams",
                .url = if (explicit_demo) "/wiki/immutable-lists?mock=1" else "/wiki/immutable-lists",
                .snippet = "Immutable lists avoid in-place updates. Lazy streams defer computation until a value is requested.",
            },
            .{
                .title = "Lecture 9: Immutable Lists and Lazy Streams",
                .url = if (explicit_demo) "/sources?type=markdown&mock=1" else "/sources?type=markdown",
                .snippet = "Lecture notes imported from the CS2030S source set and chunked for cited Q&A.",
            },
        };
        const reply: ChatReply = .{
            .message = message,
            .citations = &citations,
            .grounded = true,
            .confidence = 0.0,
            .source = "mock",
        };
        return mer.typedJson(allocator, reply);
    }

    if (containsAnyIgnoreCase(question, &.{ "revise", "lab", "practice", "before" })) {
        const message = std.fmt.allocPrint(
            allocator,
            "(demo) Based on the Lab 6 checklist for \"{s}\": review the updated deadline, check the new Coursemology test cases, and confirm each map/filter/reduce step has clear input and output types before submission.",
            .{safe_q},
        ) catch "(demo reply unavailable)";
        const citations = [_]lib.types.Citation{
            .{
                .title = "Lab 6 Functional Collections Checklist",
                .url = if (explicit_demo) "/wiki/lab-6-functional-collections?mock=1" else "/wiki/lab-6-functional-collections",
                .snippet = "Review the new Coursemology test cases before final submission.",
            },
            .{
                .title = "Lab 6: Functional Collections Brief",
                .url = if (explicit_demo) "/sources?type=assignment&mock=1" else "/sources?type=assignment",
                .snippet = "Assignment brief, due-date note, and test-case guidance for Lab 6.",
            },
        };
        const reply: ChatReply = .{
            .message = message,
            .citations = &citations,
            .grounded = true,
            .confidence = 0.0,
            .source = "mock",
        };
        return mer.typedJson(allocator, reply);
    }

    const message = std.fmt.allocPrint(
        allocator,
        "(demo) Based on the latest announcements for \"{s}\": Lab 6 has been extended to Friday 23:59. The new Coursemology test cases should be reviewed before final submission.",
        .{safe_q},
    ) catch "(demo reply unavailable)";

    const citations = [_]lib.types.Citation{
        .{
            .title = "CS2030S — Announcement: Lab 6 deadline extended",
            .url = if (explicit_demo) "/sources?type=announcement&mock=1" else "/sources?type=announcement",
            .snippet = "Lab 6 due Fri 23:59. New testcases on Coursemology.",
        },
    };

    const reply: ChatReply = .{
        .message = message,
        .citations = &citations,
        .grounded = true,
        .confidence = 0.0,
        .source = "mock",
    };

    return mer.typedJson(allocator, reply);
}

fn isBalancedSearchTreeQuestion(question: []const u8) bool {
    return containsAnyIgnoreCase(question, &.{ "avl", "balanced tree", "balanced-tree", "rotation", "search tree", "search-tree" });
}

test "balanced search tree demo questions are recognized" {
    try std.testing.expect(isBalancedSearchTreeQuestion("Why do AVL rotations preserve search-tree order?"));
    try std.testing.expect(isBalancedSearchTreeQuestion("How does a balanced tree keep searches fast?"));
    try std.testing.expect(!isBalancedSearchTreeQuestion("How should I revise for Lab 6?"));
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return i;
    }
    return null;
}
