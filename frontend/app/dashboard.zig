const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Workspace",
    .description = "WikiBase workspace overview for sources, wiki pages, cited questions, and review.",
};

const ICON_SOURCES = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"8\" height=\"18\" x=\"3\" y=\"3\" rx=\"1\"/><path d=\"M7 3v18\"/><path d=\"M20.4 18.9c.2.5-.1 1.1-.6 1.3l-1.9.7c-.5.2-1.1-.1-1.3-.6L11.1 5.1c-.2-.5.1-1.1.6-1.3l1.9-.7c.5-.2 1.1.1 1.3.6Z\"/></svg>";
const ICON_WIKI = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 7v14\"/><path d=\"M16 12h2M16 8h2\"/><path d=\"M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3Z\"/><path d=\"M21 18a1 1 0 0 0 1-1V4a1 1 0 0 0-1-1h-5a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3Z\"/></svg>";
const ICON_CARDS = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m12 2 9 5-9 5-9-5 9-5Z\"/><path d=\"m3 12 9 5 9-5M3 17l9 5 9-5\"/></svg>";
const ICON_CHAT = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M21 15a4 4 0 0 1-4 4H8l-5 3 1.5-5A8 8 0 1 1 21 15Z\"/><path d=\"M9.1 9a3 3 0 1 1 5.3 1.9c-.9.8-1.4 1.1-1.4 2.1M12 16h.01\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M5 12h14M13 6l6 6-6 6\"/></svg>";

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const synced = req.queryParam("synced") != null;
    const sync_failed = req.queryParam("sync_failed") != null;
    var source_total: usize = 12;
    var wiki_total: usize = 28;
    var due_total: usize = 16;
    var backend_ok = true;
    if (session.isAuthenticated() and req.queryParam("mock") == null) {
        const source_result = lib.backend.listSources(req.allocator, session.token);
        if (source_result.value) |parsed| {
            source_total = 0;
            for (parsed.value) |source| if (std.mem.eql(u8, source.status, "ready")) {
                source_total += 1;
            };
        } else backend_ok = false;
        const wiki_result = lib.backend.listWikiPages(req.allocator, session.token);
        if (wiki_result.value) |parsed| {
            wiki_total = 0;
            for (parsed.value) |page| if (!std.mem.eql(u8, page.page_type, "index")) {
                wiki_total += 1;
            };
        } else backend_ok = false;
        const deck_result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (deck_result.value) |parsed| {
            due_total = 0;
            for (parsed.value) |deck| due_total += deck.cards.len;
        } else backend_ok = false;
    }
    const fallback = sync_failed or (session.isAuthenticated() and !backend_ok);
    const notice_label: []const u8 = if (synced) "Sync started" else if (fallback) "Fallback preview" else if (session.isAuthenticated()) "Live preview" else "Fixture preview";
    const notice_copy: []const u8 = if (synced) "Source import has started. New evidence will appear as indexing completes." else if (fallback) "The latest saved workspace is available while the service reconnects." else if (session.isAuthenticated()) "Your connected workspace is ready for study." else "You are viewing the complete prototype with sample module data.";
    const notice_tone: []const u8 = if (fallback) "warn" else if (synced or session.isAuthenticated()) "good" else "info";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll(
        \\<header class="cp-page-header"><div><p class="cp-page-kicker">Tuesday · Week 7</p><h1 class="cp-page-title">Good afternoon, Pranav.</h1></div><div class="cp-page-actions"><a class="button button-dark button-small" href="/sources">Add source <span aria-hidden="true">＋</span></a></div></header>
        \\<div class="dashboard page-grid">
    ) catch return mer.internalError("workspace render failed");
    w.print(
        \\  <div class="notice notice-{s}" id="cp-dashboard-notice"><div><span class="status-pill status-{s}" id="cp-dashboard-mode-label">{s}</span><span id="cp-dashboard-mode-copy">{s}</span></div><label>State <select id="cp-dashboard-mode" aria-label="State"><option value="mock">Fixture</option><option value="live">Live</option><option value="fallback">Fallback</option></select></label></div>
        \\  <section class="dashboard-hero surface"><div class="dashboard-hero-copy"><p class="eyebrow">Next useful step</p><h2>Finish the path from rotations to tree height.</h2><p>Two sources are connected. One citation gap remains in the height proof.</p><div><a class="button button-dark" href="/wiki/balanced-search-trees">Continue the article
    , .{ notice_tone, notice_tone, notice_label, notice_copy }) catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("workspace render failed");
    w.writeAll("</a>") catch return mer.internalError("workspace render failed");
    if (session.isAuthenticated()) {
        w.writeAll("<form action=\"/api/sync\" method=\"post\"><input type=\"hidden\" name=\"action\" value=\"sync\"><button class=\"button button-secondary\" id=\"cp-dashboard-sync\" type=\"submit\">Sync sources</button></form>") catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("<button class=\"button button-secondary\" id=\"cp-dashboard-sync\" type=\"button\">Sync sources</button>") catch return mer.internalError("workspace render failed");
    }
    w.writeAll(
        \\</div></div><div class="knowledge-orbit" aria-label="Knowledge completion 74 percent"><svg viewBox="0 0 120 120" role="img"><circle cx="60" cy="60" r="48" pathLength="100"/><circle class="orbit-value" cx="60" cy="60" r="48" pathLength="100" stroke-dasharray="74 100"/></svg><strong>74%</strong><span>Connected</span></div></section>
        \\  <section class="metric-grid" aria-label="Workspace summary">
        \\    <article class="surface"><span class="metric-icon sky">
    ) catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_SOURCES) catch return mer.internalError("workspace render failed");
    w.print("</span><div><strong>{d}</strong><span>Sources indexed</span></div><small>+3 this week</small></article><article class=\"surface\"><span class=\"metric-icon moss\"", .{source_total}) catch return mer.internalError("workspace render failed");
    w.writeAll(">") catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_WIKI) catch return mer.internalError("workspace render failed");
    w.print("</span><div><strong>{d}</strong><span>Wiki topics</span></div><small>21 well supported</small></article><article class=\"surface\"><span class=\"metric-icon gold\">", .{wiki_total}) catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_CARDS) catch return mer.internalError("workspace render failed");
    w.print("</span><div><strong>{d}</strong><span>Cards due</span></div><small>About 12 minutes</small></article><article class=\"surface\"><span class=\"metric-icon rose\">", .{due_total}) catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_CHAT) catch return mer.internalError("workspace render failed");
    w.writeAll(
        \\</span><div><strong>9</strong><span>Cited questions</span></div><small>All grounded</small></article></section>
        \\  <div class="dashboard-columns"><section><div class="section-title"><div><h2>Active modules</h2><p>Where your knowledge is taking shape.</p></div><a href="/wiki">Open wiki</a></div><div class="module-list surface">
        \\    <a href="/wiki?module=CS2040S"><span class="module-code blue">CS</span><div><strong>CS2040S</strong><small>Data Structures and Algorithms</small><div class="slim-progress"><i style="width:82%"></i></div></div><b>82%</b></a>
        \\    <a href="/wiki?module=CS2103T"><span class="module-code green">SE</span><div><strong>CS2103T</strong><small>Software Engineering</small><div class="slim-progress"><i style="width:67%"></i></div></div><b>67%</b></a>
        \\    <a href="/wiki?module=IS1108"><span class="module-code ochre">DE</span><div><strong>IS1108</strong><small>Digital Ethics and Data Privacy</small><div class="slim-progress"><i style="width:49%"></i></div></div><b>49%</b></a>
        \\  </div></section><section><div class="section-title"><div><h2>Recent evidence</h2><p>Latest activity across the workspace.</p></div><a href="/sources">All sources</a></div><div class="activity-list surface">
        \\    <article><span class="activity-mark">
    ) catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_SOURCES) catch return mer.internalError("workspace render failed");
    w.writeAll("</span><div><strong>Lecture 08 indexed</strong><p>Created 4 topics and 11 citations.</p><small>18 minutes ago</small></div></article><article><span class=\"activity-mark\">") catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_CHAT) catch return mer.internalError("workspace render failed");
    w.writeAll("</span><div><strong>Answer grounded</strong><p>“Why do AVL rotations preserve order?”</p><small>Yesterday</small></div></article><article><span class=\"activity-mark\">") catch return mer.internalError("workspace render failed");
    w.writeAll(ICON_CARDS) catch return mer.internalError("workspace render failed");
    w.writeAll("</span><div><strong>8 cards reviewed</strong><p>Balanced trees · 75% recalled.</p><small>Yesterday</small></div></article></div></section></div></div>") catch return mer.internalError("workspace render failed");
    return lib.ui.htmlResponse(&buf);
}
