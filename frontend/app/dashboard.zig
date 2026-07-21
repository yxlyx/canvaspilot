// app/dashboard.zig — Milestone 2 workspace overview.
//
// Repurposes the M1 module dashboard into the prototype workspace home: source
// coverage, generated wiki pages, Q&A readiness, and flashcard practice state.
// Live sessions use backend workspace records. Synthetic fixture records are
// available only through the explicit demo gate.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Workspace",
    .description = "WikiBase workspace overview for sources, wiki pages, Q&A, and flashcards.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const use_mock = lib.m3.isExplicitDemo(req);
    const synced = req.queryParam("synced") != null;
    const sync_failed = req.queryParam("sync_failed") != null;
    const auth = req.queryParam("auth");

    var modules_slice: []const lib.types.Module = if (use_mock) lib.mock.modules else &.{};
    var announcements_slice: []const lib.types.Announcement = if (use_mock) lib.mock.announcements else &.{};
    var tasks_slice: []const lib.types.Task = if (use_mock) lib.mock.tasks else &.{};
    var live_sources: []const lib.types.SourceResponse = &.{};
    var live_pages: []const lib.types.WikiPageResponse = &.{};
    var live_decks: []const lib.types.FlashcardDeckResponse = &.{};
    var modules_available = true;
    var announcements_available = true;
    var tasks_available = true;
    var sources_available = true;
    var pages_available = true;
    var decks_available = true;

    if (!use_mock) {
        const modules_result = lib.backend.listModules(req.allocator, session.token);
        if (modules_result.value) |modules| {
            modules_slice = modules.value;
        } else if (modules_result.status == 401) {
            return lib.m3.liveError(req, "Workspace", 401);
        } else {
            modules_available = false;
            announcements_available = false;
        }

        if (modules_slice.len > 0) {
            const announcements_result = lib.backend.moduleAnnouncements(req.allocator, session.token, modules_slice[0].id);
            if (announcements_result.value) |announcements| announcements_slice = announcements.value else if (announcements_result.status == 401) return lib.m3.liveError(req, "Workspace", 401) else announcements_available = false;
        }
        const tasks_result = lib.backend.upcomingTasks(req.allocator, session.token);
        if (tasks_result.value) |tasks| tasks_slice = tasks.value else if (tasks_result.status == 401) return lib.m3.liveError(req, "Workspace", 401) else tasks_available = false;
        const sources_result = lib.backend.listSources(req.allocator, session.token);
        if (sources_result.value) |sources| live_sources = sources.value else if (sources_result.status == 401) return lib.m3.liveError(req, "Workspace", 401) else sources_available = false;
        const pages_result = lib.backend.listWikiPages(req.allocator, session.token);
        if (pages_result.value) |pages| live_pages = pages.value else if (pages_result.status == 401) return lib.m3.liveError(req, "Workspace", 401) else pages_available = false;
        const decks_result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (decks_result.value) |decks| live_decks = decks.value else if (decks_result.status == 401) return lib.m3.liveError(req, "Workspace", 401) else decks_available = false;
    }

    const focus: ?lib.types.Module = if (modules_slice.len > 0) modules_slice[0] else null;
    const now_secs = lib.time.nowSecs();
    var indexed_sources: usize = 0;
    var processing_sources: usize = 0;
    var total_chunks: usize = 0;
    var due_cards: usize = 0;
    var source_total: usize = 0;
    var wiki_total: usize = 0;
    var card_total: usize = 0;
    if (use_mock) {
        source_total = lib.mock.sources.len;
        wiki_total = lib.mock.wiki_pages.len;
        card_total = lib.mock.flashcards.len;
        for (lib.mock.sources) |source| {
            if (std.mem.eql(u8, source.status, "indexed")) indexed_sources += 1;
            if (std.mem.eql(u8, source.status, "processing")) processing_sources += 1;
            total_chunks += source.chunk_count;
        }
        for (lib.mock.decks) |deck| due_cards += deck.due_count;
    } else {
        source_total = live_sources.len;
        for (live_sources) |source| {
            if (std.mem.eql(u8, source.status, "ready")) indexed_sources += 1;
            if (std.mem.eql(u8, source.status, "pending") or std.mem.eql(u8, source.status, "indexing")) processing_sources += 1;
        }
        for (live_pages) |page| if (!std.mem.eql(u8, page.page_type, "index")) {
            wiki_total += 1;
        };
        for (live_decks) |deck| {
            due_cards += deck.cards.len;
            card_total += deck.card_count;
        }
    }

    var open_tasks: usize = 0;
    for (tasks_slice) |task| {
        if (!task.completed) open_tasks += 1;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoBanner(req, w) catch return mer.internalError("workspace render failed");
    const sources_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("workspace render failed");
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("workspace render failed");
    const flashcards_href = lib.m3.demoHref(req.allocator, req, "/flashcards") catch return mer.internalError("workspace render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, "/chat") catch return mer.internalError("workspace render failed");
    const sync_action = lib.m3.demoHref(req.allocator, req, "/api/sync") catch return mer.internalError("workspace render failed");

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Workspace</h1>
    ) catch return mer.internalError("workspace render failed");

    if (use_mock) {
        w.writeAll("    <div class=\"cp-page-sub\">Illustrative workspace populated with synthetic fixtures.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (focus) |module| {
        const last_synced = module.last_synced_at orelse "—";
        const when = lib.time.formatRelative(req.allocator, last_synced, now_secs) catch last_synced;
        w.print("    <div class=\"cp-page-sub\">Last synced {s}. Live source, wiki, and flashcard totals are shown below.</div>\n", .{when}) catch return mer.internalError("workspace render failed");
    } else if (modules_available) {
        w.writeAll("    <div class=\"cp-page-sub\">No workspace modules have been synced yet. Live source, wiki, and flashcard data is shown below.</div>\n") catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("    <div class=\"cp-page-sub\">Module sync status is unavailable. Other live workspace data is shown below.</div>\n") catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Review sources</a>
    , .{sources_href}) catch return mer.internalError("workspace render failed");
    if (session.isAuthenticated()) {
        w.print(
            \\    <form action="{s}" method="post" class="cp-logout">
            \\      <input type="hidden" name="action" value="sync">
            \\      <button type="submit" class="cp-btn cp-btn-primary">Sync now</button>
            \\    </form>
        , .{sync_action}) catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("    <a class=\"cp-btn cp-btn-primary\" href=\"/login\">Sign in to sync</a>\n") catch return mer.internalError("workspace render failed");
    }
    w.writeAll(
        \\  </div>
        \\</header>
    ) catch return mer.internalError("workspace render failed");

    if (synced) {
        w.writeAll("<div class=\"cp-status-banner cp-status-info\">Sync started. Source import cards will move from processing to indexed when backend jobs finish.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (sync_failed) {
        w.writeAll("<div class=\"cp-status-banner cp-status-error\">Sync failed. Live workspace data may be out of date.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (auth) |auth_state| {
        if (std.mem.eql(u8, auth_state, "registered")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Account created. Your live workspace is ready.</div>\n") catch return mer.internalError("workspace render failed");
        } else if (std.mem.eql(u8, auth_state, "signed_in")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Signed in. Your live workspace is ready.</div>\n") catch return mer.internalError("workspace render failed");
        }
    }

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("workspace render failed");
    optionalMetricCard(req, w, "Sources ready", if (sources_available) indexed_sources else null, if (sources_available) source_total else null, "Source library", "/sources") catch return mer.internalError("workspace render failed");
    optionalMetricCard(req, w, "Wiki pages", if (pages_available) wiki_total else null, if (pages_available) wiki_total else null, "Generated wiki", "/wiki") catch return mer.internalError("workspace render failed");
    optionalMetricCard(req, w, "Due cards", if (decks_available) due_cards else null, if (decks_available) card_total else null, "Flashcards", "/flashcards") catch return mer.internalError("workspace render failed");
    optionalMetricCard(req, w, "Open tasks", if (tasks_available) open_tasks else null, if (tasks_available) tasks_slice.len else null, "Ask in chat", "/chat") catch return mer.internalError("workspace render failed");
    w.writeAll("</section>\n") catch return mer.internalError("workspace render failed");

    w.print(
        \\<div class="cp-grid">
        \\<div>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Workspace focus</span><span>{s}</span></div>
    , .{if (use_mock) "illustrative" else "live"}) catch return mer.internalError("workspace render failed");

    if (focus) |module| {
        const safe_code = lib.ui.escapeSafe(req.allocator, module.code);
        const safe_name = lib.ui.escapeSafe(req.allocator, module.name);
        const safe_term = lib.ui.escapeSafe(req.allocator, module.term);
        w.print(
            \\    <div class="cp-module-summary">
            \\      <div class="cp-module-code">{s}</div>
            \\      <div class="cp-module-name">{s}</div>
            \\      <div class="cp-module-meta">{s} · {d} source records · {d} chunks</div>
            \\    </div>
        , .{ safe_code, safe_name, safe_term, source_total, total_chunks }) catch return mer.internalError("workspace render failed");
    } else if (modules_available) {
        w.writeAll("    <div class=\"cp-empty\">No workspace modules have been synced yet.</div>\n") catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("    <div class=\"cp-empty\">Module details are temporarily unavailable.</div>\n") catch return mer.internalError("workspace render failed");
    }
    w.writeAll("  </section>\n") catch return mer.internalError("workspace render failed");

    w.print(
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Source library preview</span><a href="{s}">View all</a></div>
        \\    <div class="cp-source-list">
    , .{sources_href}) catch return mer.internalError("workspace render failed");

    if (use_mock) {
        for (lib.mock.sources, 0..) |source, idx| {
            if (idx >= 3) break;
            renderSourcePreview(req, w, source, now_secs) catch return mer.internalError("workspace render failed");
        }
    } else if (!sources_available) {
        w.writeAll("      <div class=\"cp-empty\">Source data is temporarily unavailable.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (live_sources.len == 0) {
        w.writeAll("      <div class=\"cp-empty\">No sources have been imported yet.</div>\n") catch return mer.internalError("workspace render failed");
    } else {
        for (live_sources, 0..) |source, idx| {
            if (idx >= 3) break;
            renderLiveSourcePreview(req, w, source, now_secs) catch return mer.internalError("workspace render failed");
        }
    }

    w.writeAll(
        \\    </div>
        \\  </section>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Recent announcements</span></div>
        \\    <ul class="cp-feed">
    ) catch return mer.internalError("workspace render failed");

    var ann_shown: usize = 0;
    if (focus) |module| for (announcements_slice) |a| {
        if (!std.mem.eql(u8, a.module_id, module.id)) continue;
        if (ann_shown >= 3) break;
        ann_shown += 1;
        const safe_title = lib.ui.escapeSafe(req.allocator, a.title);
        const summary = a.summary orelse a.content;
        const safe_summary = lib.ui.escapeSafe(req.allocator, summary);
        const when = lib.time.formatRelative(req.allocator, a.posted_at, now_secs) catch "—";
        w.print(
            \\      <li class="cp-feed-item">
            \\        <div class="cp-feed-title">{s}</div>
            \\        <div class="cp-feed-meta">{s}</div>
            \\        <div class="cp-feed-body">{s}</div>
            \\      </li>
        , .{ safe_title, when, safe_summary }) catch return mer.internalError("workspace render failed");
    };
    if (!announcements_available) {
        w.writeAll("      <li class=\"cp-empty\">Announcements are temporarily unavailable.</li>\n") catch return mer.internalError("workspace render failed");
    } else if (ann_shown == 0) {
        w.writeAll("      <li class=\"cp-empty\">No announcements indexed yet.</li>\n") catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\    </ul>
        \\  </section>
        \\</div>
        \\<div>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Generated wiki</span><a href="{s}">View all</a></div>
        \\    <div class="cp-wiki-list">
    , .{wiki_href}) catch return mer.internalError("workspace render failed");

    if (use_mock) {
        for (lib.mock.wiki_pages) |page| {
            const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
            const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
            const path = std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{page.slug}) catch "/wiki/immutable-lists";
            const href = lib.m3.demoHref(req.allocator, req, path) catch return mer.internalError("workspace render failed");
            w.print(
                \\      <a class="cp-wiki-row" href="{s}">
                \\        <span>{s}</span>
                \\        <small>{s}</small>
                \\      </a>
            , .{ href, safe_title, safe_summary }) catch return mer.internalError("workspace render failed");
        }
    } else if (!pages_available) {
        w.writeAll("      <div class=\"cp-empty\">Wiki data is temporarily unavailable.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (wiki_total == 0) {
        w.writeAll("      <div class=\"cp-empty\">No wiki pages have been generated yet.</div>\n") catch return mer.internalError("workspace render failed");
    } else {
        for (live_pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index")) continue;
            const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
            const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
            const href = std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{page.slug}) catch "/wiki";
            w.print("      <a class=\"cp-wiki-row\" href=\"{s}\"><span>{s}</span><small>{s}</small></a>\n", .{ href, safe_title, safe_summary }) catch return mer.internalError("workspace render failed");
        }
    }

    w.print(
        \\    </div>
        \\  </section>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Flashcard practice</span><a href="{s}">Practice</a></div>
    , .{flashcards_href}) catch return mer.internalError("workspace render failed");

    if (use_mock and lib.mock.decks.len > 0) {
        const deck = lib.mock.decks[0];
        const safe_title = lib.ui.escapeSafe(req.allocator, deck.title);
        const safe_desc = lib.ui.escapeSafe(req.allocator, deck.description);
        const path = std.fmt.allocPrint(req.allocator, "/flashcards?deck={s}", .{deck.id}) catch "/flashcards";
        const href = lib.m3.demoHref(req.allocator, req, path) catch return mer.internalError("workspace render failed");
        w.print(
            \\    <div class="cp-study-card">
            \\      <div class="cp-study-title">{s}</div>
            \\      <p>{s}</p>
            \\      <div class="cp-module-meta">{d} due · {d} cards total</div>
            \\      <a class="cp-btn cp-btn-primary" href="{s}">Start review</a>
            \\    </div>
        , .{ safe_title, safe_desc, deck.due_count, deck.card_count, href }) catch return mer.internalError("workspace render failed");
    } else if (!use_mock and !decks_available) {
        w.writeAll("    <div class=\"cp-empty\">Flashcard data is temporarily unavailable.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (!use_mock and live_decks.len > 0) {
        const deck = live_decks[0];
        const safe_title = lib.ui.escapeSafe(req.allocator, deck.title);
        const safe_desc = lib.ui.escapeSafe(req.allocator, deck.description);
        const href = std.fmt.allocPrint(req.allocator, "/flashcards?deck={s}", .{deck.id}) catch "/flashcards";
        w.print("    <div class=\"cp-study-card\"><div class=\"cp-study-title\">{s}</div><p>{s}</p><div class=\"cp-module-meta\">{d} cards total</div><a class=\"cp-btn cp-btn-primary\" href=\"{s}\">Start review</a></div>\n", .{ safe_title, safe_desc, deck.card_count, href }) catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("    <div class=\"cp-empty\">No flashcard decks have been generated yet.</div>\n") catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\  </section>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Ask WikiBase</span></div>
        \\    <p class="cp-muted-copy">Use cited Q&A across the indexed source set, then jump back to the exact source or wiki page.</p>
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Open Q&A</a>
        \\  </section>
        \\</div>
        \\</div>
    , .{chat_href}) catch return mer.internalError("workspace render failed");

    if (processing_sources > 0) {
        w.print("<div class=\"cp-status-banner cp-status-warn\" style=\"margin-top:16px\">{d} source import is still processing; the source library shows the loading state.</div>\n", .{processing_sources}) catch return mer.internalError("workspace render failed");
    }

    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn optionalMetricCard(
    req: mer.Request,
    w: *std.Io.Writer,
    label: []const u8,
    value: ?usize,
    sub_value: ?usize,
    action: []const u8,
    href: []const u8,
) !void {
    if (value) |available| return metricCard(req, w, label, available, sub_value.?, action, href);
    const demo_href = try lib.m3.demoHref(req.allocator, req, href);
    try w.print(
        \\  <a class="cp-metric-card" href="{s}">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">Unavailable</span>
        \\    <span class="cp-metric-sub">live metric temporarily unavailable · {s}</span>
        \\  </a>
    , .{ demo_href, label, action });
}

fn metricCard(
    req: mer.Request,
    w: *std.Io.Writer,
    label: []const u8,
    value: usize,
    sub_value: usize,
    action: []const u8,
    href: []const u8,
) !void {
    const demo_href = try lib.m3.demoHref(req.allocator, req, href);
    try w.print(
        \\  <a class="cp-metric-card" href="{s}">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">{d}</span>
        \\    <span class="cp-metric-sub">{d} total · {s}</span>
        \\  </a>
    , .{ demo_href, label, value, sub_value, action });
}

fn renderSourcePreview(
    req: mer.Request,
    w: *std.Io.Writer,
    source: lib.types.WorkspaceSource,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, source.summary);
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const status_cls = sourceStatusClass(source.status);
    try w.print(
        \\      <article class="cp-source-card">
        \\        <div class="cp-source-card-head">
        \\          <span class="cp-source-type">{s}</span>
        \\          <span class="{s}">{s}</span>
        \\        </div>
        \\        <div class="cp-source-title">{s}</div>
        \\        <p>{s}</p>
        \\        <div class="cp-module-meta">{d} chunks · updated {s}</div>
        \\      </article>
    , .{ source.source_type, status_cls, source.status, safe_title, safe_summary, source.chunk_count, when });
}

fn renderLiveSourcePreview(
    req: mer.Request,
    w: *std.Io.Writer,
    source: lib.types.SourceResponse,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, source.citation_label);
    const safe_type = lib.ui.escapeSafe(req.allocator, source.source_type);
    const safe_status = lib.ui.escapeSafe(req.allocator, source.status);
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const status_cls = sourceStatusClass(source.status);
    try w.print(
        \\      <article class="cp-source-card">
        \\        <div class="cp-source-card-head"><span class="cp-source-type">{s}</span><span class="{s}">{s}</span></div>
        \\        <div class="cp-source-title">{s}</div><p>{s}</p>
        \\        <div class="cp-module-meta">updated {s}</div>
        \\      </article>
    , .{ safe_type, status_cls, safe_status, safe_title, safe_summary, when });
}

fn sourceStatusClass(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "indexed") or std.mem.eql(u8, status, "ready")) return "cp-source-status cp-source-status-indexed";
    if (std.mem.eql(u8, status, "needs review") or std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "archived")) return "cp-source-status cp-source-status-review";
    if (std.mem.eql(u8, status, "processing") or std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "indexing")) return "cp-source-status cp-source-status-processing";
    return "cp-source-status";
}

fn renderEmpty(req: mer.Request, demo: bool) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const session = lib.session.fromRequest(req);
    lib.m3.demoBanner(req, w) catch return mer.internalError("workspace render failed");
    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("workspace render failed");
    }
    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Workspace</h1>
        \\    <div class="cp-page-sub">No workspace modules synced yet.</div>
        \\  </div>
    ) catch return mer.internalError("workspace render failed");
    if (session.isAuthenticated()) {
        w.writeAll(
            \\  <form action="/api/sync" method="post" class="cp-logout">
            \\    <input type="hidden" name="action" value="sync">
            \\    <button type="submit" class="cp-btn cp-btn-primary">Sync now</button>
            \\  </form>
        ) catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("  <a class=\"cp-btn cp-btn-primary\" href=\"/login\">Sign in to sync</a>\n") catch return mer.internalError("workspace render failed");
    }
    w.writeAll("</header>") catch return mer.internalError("workspace render failed");
    if (req.queryParam("auth")) |auth_state| {
        if (std.mem.eql(u8, auth_state, "registered")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Account created. Your live workspace is ready.</div>") catch return mer.internalError("workspace render failed");
        } else if (std.mem.eql(u8, auth_state, "signed_in")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Signed in. Your live workspace is ready.</div>") catch return mer.internalError("workspace render failed");
        }
    }
    w.writeAll("<section class=\"cp-card\"><div class=\"cp-empty\">") catch return mer.internalError("workspace render failed");
    if (demo) {
        w.writeAll("No synthetic workspace modules are configured for this demo.") catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("No workspace modules have been synced yet. Sync your account to populate this live workspace.") catch return mer.internalError("workspace render failed");
    }
    w.writeAll("</div></section>") catch return mer.internalError("workspace render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
