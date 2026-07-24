const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Ask",
    .description = "Ask source-grounded questions and inspect the supporting evidence.",
    .extra_head = "<script defer src=\"/app.js?v=wikibase-3\"></script>",
};

const ICON_FILE = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z\"/><path d=\"M14 2v6h6M8 13h8M8 17h6\"/></svg>";
const ICON_WEB = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M3 12h18M12 3a15 15 0 0 1 0 18M12 3a15 15 0 0 0 0 18\"/></svg>";
const ICON_SHIELD = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M20 13c0 5-3.5 7.5-8 9-4.5-1.5-8-4-8-9V5l8-3 8 3v8Z\"/><path d=\"m9 12 2 2 4-4\"/></svg>";
const ICON_ASK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M21 15a4 4 0 0 1-4 4H7l-4 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4Z\"/><path d=\"M8 8h8M8 12h5\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M7 17 17 7M7 7h10v10\"/></svg>";
const ICON_SEND = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m22 2-7 20-4-9-9-4Z\"/><path d=\"M22 2 11 13\"/></svg>";

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const use_mock = lib.m3.isExplicitDemo(req);
    const chat_endpoint: []const u8 = if (use_mock) "/api/chat?mock=1" else "/api/chat";
    const selected_module = req.queryParam("module") orelse "";
    const sources_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("ask render failed");

    var modules_slice: []const lib.types.Module = if (use_mock) lib.mock.modules else &.{};
    if (!use_mock) {
        const result = lib.backend.listModules(req.allocator, session.token);
        if (result.value) |modules| modules_slice = modules.value else return lib.m3.liveError(req, "Ask", result.status);
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("ask render failed");
    w.print(
        "<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Grounded Q&amp;A{s}</p><h1 class=\"cp-page-title\">Ask your knowledge base</h1></div></header>",
        .{if (use_mock) " · synthetic demo" else ""},
    ) catch return mer.internalError("ask render failed");
    if (!use_mock and modules_slice.len == 0) {
        w.writeAll("<div class=\"cp-status-banner cp-status-info\">No modules have been synced yet. You can still ask about imported sources.</div>\n") catch return mer.internalError("ask render failed");
    }
    w.writeAll(
        \\<div class="chat-page">
        \\  <aside class="chat-context surface">
        \\    <div><p class="eyebrow">Question scope</p><label class="field"><span>Module</span><select id="cp-chat-module" aria-label="Module">
    ) catch return mer.internalError("ask render failed");

    if (modules_slice.len == 0) {
        w.writeAll("      <option value=\"\" data-code=\"All sources\">All imported sources</option>\n") catch return mer.internalError("ask render failed");
    } else {
        for (modules_slice) |module| {
            const safe_id = lib.ui.escapeSafe(req.allocator, module.id);
            const safe_code = lib.ui.escapeSafe(req.allocator, module.code);
            const safe_name = lib.ui.escapeSafe(req.allocator, module.name);
            const selected: []const u8 = if (std.mem.eql(u8, selected_module, module.id)) " selected" else "";
            w.print("      <option value=\"{s}\" data-code=\"{s}\"{s}>{s} {s}</option>\n", .{ safe_id, safe_code, selected, safe_code, safe_name }) catch return mer.internalError("ask render failed");
        }
    }

    w.writeAll("    </select></label></div>\n") catch return mer.internalError("ask render failed");
    if (use_mock) {
        w.print(
            \\    <div class="context-sources">
            \\      <div class="section-title"><div><h2>Evidence in scope</h2><p>3 sources · 146 chunks</p></div></div>
            \\      <a href="{s}"><span class="mini-file">
        , .{sources_href}) catch return mer.internalError("ask render failed");
        w.writeAll(ICON_FILE) catch return mer.internalError("ask render failed");
        w.print(
            \\      </span><div><strong>Lecture 08</strong><small>Balanced search trees</small></div><b>42p</b></a>
            \\      <a href="{s}"><span class="mini-file">
        , .{sources_href}) catch return mer.internalError("ask render failed");
        w.writeAll(ICON_FILE) catch return mer.internalError("ask render failed");
        w.print(
            \\      </span><div><strong>Tutorial 05</strong><small>Rotations and height</small></div><b>8p</b></a>
            \\      <a href="{s}"><span class="mini-file link">
        , .{sources_href}) catch return mer.internalError("ask render failed");
        w.writeAll(ICON_WEB) catch return mer.internalError("ask render failed");
        w.writeAll(
            \\      </span><div><strong>Search-tree reading</strong><small>Recommended chapter</small></div><b>Web</b></a>
            \\    </div>
        ) catch return mer.internalError("ask render failed");
    } else {
        w.print("    <div class=\"context-sources\"><div class=\"section-title\"><div><h2>Evidence in scope</h2><p>Synced sources</p></div></div><a href=\"{s}\">Browse the source library</a></div>\n", .{sources_href}) catch return mer.internalError("ask render failed");
    }
    w.writeAll("    <div class=\"grounding-note\"><span>") catch return mer.internalError("ask render failed");
    w.writeAll(ICON_SHIELD) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\    </span><p><strong>Citations required</strong>Answers use only the selected module and always expose their evidence.</p></div>
        \\  </aside>
        \\  <section class="chat-thread surface" aria-label="Question and answer conversation">
        \\    <header><div><span class="status-pill status-good">Sources ready</span><span id="cp-chat-module-code"></span></div><button id="cp-chat-clear" type="button" disabled>Clear conversation</button></header>
        \\    <div class="turns" id="cp-chat-log" role="log" aria-live="polite">
        \\      <div class="chat-welcome" id="cp-chat-welcome"><span class="ask-orb">
    ) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ASK) catch return mer.internalError("ask render failed");

    const welcome_copy: []const u8 = if (use_mock) "Ask a question about a sample module. WikiBase will answer from fixture sources and show where each claim came from." else "Ask a question about your selected module. WikiBase will answer from your synced sources and show where each claim came from.";
    const prompt_one: []const u8 = if (use_mock) "Why do AVL rotations preserve the search-tree order?" else "Summarise the key ideas in my sources.";
    const prompt_two: []const u8 = if (use_mock) "Compare breadth-first and depth-first search." else "What should I revise next?";
    const prompt_three: []const u8 = if (use_mock) "Which sources discuss meaningful digital consent?" else "Which sources cover this topic?";
    w.print(
        \\      </span><p class="eyebrow">Start from the evidence</p><h2>What would you like to make clearer?</h2><p>{s}</p>
        \\      <div class="suggestion-list">
        \\        <button type="button" data-prompt="{s}"><span>{s}</span><b>
    , .{ welcome_copy, prompt_one, prompt_one }) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("ask render failed");
    w.print(
        \\        </b></button>
        \\        <button type="button" data-prompt="{s}"><span>{s}</span><b>
    , .{ prompt_two, prompt_two }) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("ask render failed");
    w.print(
        \\        </b></button>
        \\        <button type="button" data-prompt="{s}"><span>{s}</span><b>
    , .{ prompt_three, prompt_three }) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("ask render failed");
    w.print(
        \\        </b></button>
        \\      </div></div>
        \\    </div>
        \\    <form class="chat-composer" id="cp-chat-form" autocomplete="off" data-endpoint="{s}">
        \\      <label for="cp-chat-input">Ask from <span id="cp-chat-composer-code"></span></label>
        \\      <div><textarea id="cp-chat-input" name="message" rows="2" placeholder="Ask a question about your sources…" aria-label="Ask from selected sources" required></textarea><button id="cp-chat-send" type="submit" aria-label="Send question" disabled>
    , .{chat_endpoint}) catch return mer.internalError("ask render failed");
    w.writeAll(ICON_SEND) catch return mer.internalError("ask render failed");
    w.writeAll(
        \\      </button></div><small>Answers may be incomplete. Verify important claims in the cited source.</small>
        \\    </form>
        \\    <noscript><div class="cp-status-banner cp-status-warn">Ask requires JavaScript. You can still browse the source library.</div></noscript>
        \\  </section>
        \\</div>
    ) catch return mer.internalError("ask render failed");

    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
