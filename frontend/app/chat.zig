// app/chat.zig — chat shell.
//
// Proposal M1 1c: a user asks a question, the system retrieves relevant
// chunks via cosine similarity and returns a grounded response with source
// links. SSR renders the page shell + module selector; a small browser
// script (public/app.js) POSTs the question to merjs `/api/chat`, which
// proxies to the FastAPI SSE endpoint with the HttpOnly cookie attached
// server-side, then aggregates the SSE frames into a single JSON reply.
// Token-by-token streaming is Milestone 2 polish.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Chat",
    .description = "Ask CanvasPilot about your modules.",
    .extra_head = "<script defer src=\"/app.js\"></script>",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    const selected_module = req.queryParam("module") orelse "";

    var modules_slice: []const lib.types.Module = lib.mock.modules;
    if (!use_mock) {
        const m = lib.backend.listModules(req.allocator, session.token);
        if (m.value) |v| modules_slice = v.value;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Chat</h1>
        \\    <div class="cp-page-sub">Grounded in your Canvas modules. Citations included.</div>
        \\  </div>
        \\</header>
        \\
    ) catch return mer.internalError("chat render failed");

    if (use_mock) {
        w.writeAll("<div class=\"cp-status-banner cp-status-info\">Showing prototype chat — sign in to connect live modules.</div>\n") catch return mer.internalError("chat render failed");
    }

    w.writeAll(
        \\<section class="cp-chat-shell" id="cp-chat">
        \\  <noscript><div class="cp-status-banner cp-status-warn">Chat needs JavaScript. Browse the <a href="/wiki">wiki</a> or <a href="/flashcards">flashcards</a> in the meantime.</div></noscript>
        \\  <div class="cp-chat-log" id="cp-chat-log" role="log" aria-live="polite">
        \\    <div class="cp-chat-msg cp-chat-msg-system">
        \\      Try: "What's due this week in CS2030S?" or "Summarise today's announcements".
        \\    </div>
        \\  </div>
        \\  <div class="cp-chat-suggestions">
        \\    <button type="button" class="cp-chip" data-prompt="What's due this week in CS2030S?">Due this week</button>
        \\    <button type="button" class="cp-chip" data-prompt="Summarise today's announcements">Announcements</button>
        \\    <button type="button" class="cp-chip" data-prompt="Explain immutable lists">Immutable lists</button>
        \\  </div>
        \\  <form class="cp-chat-form" id="cp-chat-form" autocomplete="off">
        \\    <select class="cp-chat-module" id="cp-chat-module" name="module" aria-label="Module filter">
        \\      <option value="">All modules</option>
        \\
    ) catch return mer.internalError("chat render failed");

    for (modules_slice) |m| {
        const safe_code = lib.ui.escape(req.allocator, m.code) catch m.code;
        const safe_name = lib.ui.escape(req.allocator, m.name) catch m.name;
        const selected: []const u8 = if (std.mem.eql(u8, selected_module, m.id)) " selected" else "";
        w.print(
            "      <option value=\"{s}\"{s}>{s} — {s}</option>\n",
            .{ m.id, selected, safe_code, safe_name },
        ) catch return mer.internalError("chat render failed");
    }

    w.writeAll(
        \\    </select>
        \\    <input type="text" class="cp-chat-input" id="cp-chat-input" name="message"
        \\           aria-label="Ask CanvasPilot" placeholder="Ask about your modules…" required>
        \\    <button type="submit" class="cp-btn cp-btn-primary" id="cp-chat-send">Send</button>
        \\  </form>
        \\</section>
        \\<p class="cp-page-sub" style="margin-top:12px">
        \\  Answers are grounded in your synced Canvas modules. Sources appear inline below each reply.
        \\</p>
        \\
    ) catch return mer.internalError("chat render failed");

    return lib.ui.htmlResponse(&buf);
}
