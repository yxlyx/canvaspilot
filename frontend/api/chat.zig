// api/chat.zig — Milestone 1 chat proxy.
//
// Proposal M1 1c: "user can ask a question, system retrieves relevant chunks
// via cosine similarity and returns a grounded response with source links".
//
// The browser POSTs JSON {message, module_id, history} here. We re-serialize
// the body, forward it to FastAPI /api/chat with the user's bearer token
// (read from the HttpOnly cp_session cookie — never exposed to the browser),
// then read the Server-Sent Events response, aggregate the streamed tokens
// and citations, and return a single JSON {message, citations, grounded}
// reply.
//
// This is server-side aggregation rather than a streaming pass-through.
// The proposal only requires "returns a grounded response with source links",
// not token-by-token streaming — that's Milestone 2 polish.
//
// If the backend is unreachable or returns an error, we fall back to a
// canned mock reply so the demo flow still works end-to-end offline.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const log = std.log.scoped(.chat_api);

const ChatBody = struct {
    message: []const u8 = "",
    module_id: ?[]const u8 = null,
    history: []const lib.types.ChatMessage = &.{},
};

const ChatReply = struct {
    message: []const u8,
    citations: []const lib.types.Citation,
    grounded: bool = true,
    confidence: f64 = 0.0,
    source: []const u8 = "backend", // "backend" or "mock"
};

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) {
        return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    }
    if (req.body.len == 0) {
        return mer.badRequest("expected JSON body");
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

    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) {
        // For demo / sign-out users we still return a usable reply.
        return mockReply(req.allocator, body.message);
    }

    // Forward to FastAPI; aggregate SSE frames into a single reply.
    if (callBackend(req.allocator, session.token, body)) |reply| {
        return mer.typedJson(req.allocator, reply);
    } else |e| {
        log.warn("chat: backend error: {s} — falling back to mock", .{@errorName(e)});
        return mockReply(req.allocator, body.message);
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
) (BackendError || std.mem.Allocator.Error)!ChatReply {
    const cfg = lib.config.load();
    const url = std.fmt.allocPrint(allocator, "{s}/api/chat", .{cfg.backend_url}) catch
        return error.SerializeFailed;
    const bearer = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch
        return error.SerializeFailed;

    // Re-serialize the body so we control the schema sent to FastAPI.
    var out: std.Io.Writer.Allocating = .init(allocator);
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
    }) catch return error.BackendUnreachable;

    const status_int: u16 = @intFromEnum(res.status);
    if (status_int == 401 or status_int == 403) return error.AuthFailed;
    if (status_int >= 400) {
        log.warn("chat: backend returned {d}: {s}", .{ status_int, res.body });
        return error.BackendBadStatus;
    }

    return try aggregateSse(allocator, res.body);
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
// `done` may also carry a `message` field for the no-results path.

const TokenEvent = struct { text: []const u8 = "" };
const CitationsEvent = struct { citations: []const lib.types.Citation = &.{} };
const DoneEvent = struct {
    grounded: bool = false,
    confidence: f64 = 0.0,
    message: ?[]const u8 = null,
};

fn aggregateSse(
    allocator: std.mem.Allocator,
    sse: []const u8,
) (BackendError || std.mem.Allocator.Error)!ChatReply {
    var message_buf: std.ArrayListUnmanaged(u8) = .empty;
    var citations: []const lib.types.Citation = &.{};
    var grounded = false;
    var confidence: f64 = 0.0;
    var override_message: ?[]const u8 = null;

    var frame_it = std.mem.splitSequence(u8, sse, "\n\n");
    while (frame_it.next()) |frame| {
        const trimmed = std.mem.trim(u8, frame, "\r\n \t");
        if (trimmed.len == 0) continue;

        var event: []const u8 = "message";
        var data: []const u8 = "";
        var line_it = std.mem.splitScalar(u8, trimmed, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "event:")) {
                event = std.mem.trim(u8, line[6..], " ");
            } else if (std.mem.startsWith(u8, line, "data:")) {
                data = std.mem.trim(u8, line[5..], " ");
            }
        }
        if (data.len == 0) continue;

        if (std.mem.eql(u8, event, "token")) {
            const evt = std.json.parseFromSlice(TokenEvent, allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            try message_buf.appendSlice(allocator, evt.value.text);
        } else if (std.mem.eql(u8, event, "citations")) {
            const evt = std.json.parseFromSlice(CitationsEvent, allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            citations = evt.value.citations;
        } else if (std.mem.eql(u8, event, "done")) {
            const evt = std.json.parseFromSlice(DoneEvent, allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            grounded = evt.value.grounded;
            confidence = evt.value.confidence;
            override_message = evt.value.message;
        }
    }

    const final_message = if (override_message) |m| m else try message_buf.toOwnedSlice(allocator);

    return .{
        .message = if (final_message.len > 0)
            final_message
        else
            "I don't have enough information from your Canvas modules to answer this.",
        .citations = citations,
        .grounded = grounded,
        .confidence = confidence,
        .source = "backend",
    };
}

// ── Mock fallback ───────────────────────────────────────────────────────────

fn mockReply(allocator: std.mem.Allocator, question: []const u8) mer.Response {
    const safe_q = lib.ui.escape(allocator, question) catch question;
    const message = std.fmt.allocPrint(
        allocator,
        "(demo) Based on the latest announcements in your synced modules, here's what I found about \"{s}\": Lab 6 has been extended to Friday 23:59. Sources are linked below.",
        .{safe_q},
    ) catch "(demo reply unavailable)";

    const citations = [_]lib.types.Citation{
        .{
            .title = "CS2030S — Announcement: Lab 6 deadline extended",
            .url = "/dashboard",
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
