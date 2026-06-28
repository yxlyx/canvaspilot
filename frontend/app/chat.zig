const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Chat",
    .description = "Ask CanvasPilot about your modules.",
    .extra_head = "<script defer src=\"/app.js?v=course-os-2\"></script>",
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

    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("chat render failed");
    }

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <div class="cp-page-kicker">Cited Q&amp;A</div>
        \\    <div class="cp-page-title">Ask your workspace</div>
        \\    <div class="cp-page-sub">Grounded in your synced modules and source library. Citations appear below each reply.</div>
        \\  </div>
        \\</header>
        \\<div class="cp-chat-layout">
        \\  <section class="cp-chat-shell" id="cp-chat">
        \\    <div class="cp-chat-log" id="cp-chat-log" role="log" aria-live="polite">
        \\      <div class="cp-chat-msg cp-chat-msg-system">
        \\        Try: "What's due this week in CS2030S?" or "Summarise today's announcements".
        \\      </div>
        \\    </div>
        \\    <form class="cp-chat-form" id="cp-chat-form" autocomplete="off">
        \\      <select class="cp-chat-module" id="cp-chat-module" name="module">
        \\        <option value="">All modules</option>
        \\
    ) catch return mer.internalError("chat render failed");

    for (modules_slice) |m| {
        const safe_code = lib.ui.escape(req.allocator, m.code) catch m.code;
        const safe_name = lib.ui.escape(req.allocator, m.name) catch m.name;
        const selected: []const u8 = if (std.mem.eql(u8, selected_module, m.id)) " selected" else "";
        w.print(
            "        <option value=\"{s}\"{s}>{s} — {s}</option>\n",
            .{ m.id, selected, safe_code, safe_name },
        ) catch return mer.internalError("chat render failed");
    }

    w.writeAll(
        \\      </select>
        \\      <input type="text" class="cp-chat-input" id="cp-chat-input" name="message"
        \\             placeholder="Ask about your modules…" required>
        \\      <button type="submit" class="cp-btn cp-btn-primary" id="cp-chat-send">Send</button>
        \\    </form>
        \\  </section>
        \\  <aside class="cp-chat-side" aria-label="Question ideas">
        \\    <div class="cp-card-title"><span>Try asking</span><span>grounded</span></div>
        \\    <div class="cp-prompt-list">
        \\      <div class="cp-prompt-card">What is due this week?</div>
        \\      <div class="cp-prompt-card">Summarise the latest announcement.</div>
        \\      <div class="cp-prompt-card">Explain lazy streams with citations.</div>
        \\      <div class="cp-prompt-card">What should I revise before lab?</div>
        \\    </div>
        \\    <p class="cp-page-sub" style="margin-top:16px">
        \\      The chat keeps the existing module selector, retry behavior, and citation rendering while using the course workspace style.
        \\    </p>
        \\  </aside>
        \\</div>
        \\
    ) catch return mer.internalError("chat render failed");

    return lib.ui.htmlResponse(&buf);
}
