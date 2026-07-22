const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Ask",
    .description = "Ask source-grounded questions and inspect the supporting evidence.",
};

const ICON_FILE = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z\"/><path d=\"M14 2v6h6M8 13h8M8 17h6\"/></svg>";
const ICON_WEB = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18\"/></svg>";
const ICON_SHIELD = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M20 13c0 5-3.5 7.5-8 9-4.5-1.5-8-4-8-9V5l8-3 8 3v8Z\"/><path d=\"m9 12 2 2 4-4\"/></svg>";
const ICON_ASK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M21 15a4 4 0 0 1-4 4H7l-4 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4Z\"/><path d=\"M8 8h8M8 12h5\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M7 17 17 7M7 7h10v10\"/></svg>";
const ICON_SEND = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m22 2-7 20-4-9-9-4Z\"/><path d=\"M22 2 11 13\"/></svg>";

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    const selected_module = req.queryParam("module") orelse "";

    var modules_slice: []const lib.types.Module = lib.mock.modules;
    if (!use_mock) {
        const result = lib.backend.listModules(req.allocator, session.token);
        if (result.value) |parsed| modules_slice = parsed.value;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("ask render failed");
    }

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div><p class="cp-page-kicker">Grounded Q&amp;A</p><h1 class="cp-page-title">Ask your knowledge base</h1></div>
        \\</header>
        \\<div class="chat-page">
        \\  <aside class="chat-context surface">
        \\    <div><p class="eyebrow">Question scope</p><label class="field"><span>Module</span><select id="cp-chat-module" aria-label="Module">
    ) catch return mer.internalError("ask render failed");

    if (use_mock) {
        w.writeAll(
            \\      <option value="cs2040s">CS2040S Data Structures</option>
            \\      <option value="cs2103t">CS2103T Software Engineering</option>
            \\      <option value="is1108">IS1108 Digital Ethics</option>
        ) catch return mer.internalError("ask render failed");
    } else {
        for (modules_slice) |module| {
            const safe_id = lib.ui.escape(req.allocator, module.id) catch module.id;
            const safe_code = lib.ui.escape(req.allocator, module.code) catch module.code;
            const safe_name = lib.ui.escape(req.allocator, module.name) catch module.name;
            const selected: []const u8 = if (std.mem.eql(u8, selected_module, module.id)) " selected" else "";
            w.print("<option value=\"{s}\" data-code=\"{s}\"{s}>{s} {s}</option>", .{ safe_id, safe_code, selected, safe_code, safe_name }) catch return mer.internalError("ask render failed");
        }
    }

    w.writeAll(
        \\    </select></label></div>
        \\    <div class="context-sources">
        \\      <div class="section-title"><div><h2>Evidence in scope</h2><p>3 sources · 146 chunks</p></div></div>
        \\      <a href="/sources"><span class="mini-file">
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_FILE) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\      </span><div><strong>Lecture 08</strong><small>Balanced search trees</small></div><b>42p</b></a>
        \\      <a href="/sources"><span class="mini-file">
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_FILE) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\      </span><div><strong>Tutorial 05</strong><small>Rotations and height</small></div><b>8p</b></a>
        \\      <a href="/sources"><span class="mini-file link">
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_WEB) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\      </span><div><strong>Search-tree reading</strong><small>Recommended chapter</small></div><b>Web</b></a>
        \\    </div>
        \\    <div class="grounding-note"><span>
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_SHIELD) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\    </span><p><strong>Citations required</strong>Answers use only the selected module and always expose their evidence.</p></div>
        \\  </aside>
        \\  <section class="chat-thread surface" aria-label="Question and answer conversation">
        \\    <header><div><span class="status-pill status-good">Sources ready</span><span id="cp-chat-module-code">CS2040S</span></div><button id="cp-chat-clear" type="button" disabled>Clear conversation</button></header>
        \\    <div class="turns" id="cp-chat-log" role="log" aria-live="polite">
        \\      <div class="chat-welcome" id="cp-chat-welcome"><span class="ask-orb">
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ASK) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\      </span><p class="eyebrow">Start from the evidence</p><h2>What would you like to make clearer?</h2><p>Ask a question about your selected module. WikiBase will answer from your indexed sources and show where each claim came from.</p>
        \\      <div class="suggestion-list">
        \\        <button type="button" data-prompt="Why do AVL rotations preserve the search-tree order?"><span>Why do AVL rotations preserve the search-tree order?</span><b>
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\        </b></button>
        \\        <button type="button" data-prompt="Compare breadth-first and depth-first search."><span>Compare breadth-first and depth-first search.</span><b>
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\        </b></button>
        \\        <button type="button" data-prompt="Which sources discuss meaningful digital consent?"><span>Which sources discuss meaningful digital consent?</span><b>
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\        </b></button>
        \\      </div></div>
        \\    </div>
        \\    <form class="chat-composer" id="cp-chat-form" autocomplete="off">
        \\      <label for="cp-chat-input">Ask from <span id="cp-chat-composer-code">CS2040S</span></label>
        \\      <div><textarea id="cp-chat-input" name="message" rows="2" placeholder="Ask a question about your sources…" aria-label="Ask from CS2040S" required></textarea><button id="cp-chat-send" type="submit" aria-label="Send question" disabled>
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_SEND) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\      </button></div><small>Answers may be incomplete. Verify important claims in the cited source.</small>
        \\    </form>
        \\    <noscript><div class="cp-status-banner cp-status-warn">Ask requires JavaScript. You can still browse the <a href="/wiki">wiki</a> and <a href="/sources">source library</a>.</div></noscript>
        \\  </section>
        \\</div>
    ) catch return mer.internalError("ask render failed");

    return lib.ui.htmlResponse(&buf);
}
