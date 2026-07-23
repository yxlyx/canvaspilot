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

const ICON_SOURCES = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"8\" height=\"18\" x=\"3\" y=\"3\" rx=\"1\"/><path d=\"M7 3v18\"/><path d=\"M20.4 18.9c.2.5-.1 1.1-.6 1.3l-1.9.7c-.5.2-1.1-.1-1.3-.6L11.1 5.1c-.2-.5.1-1.1.6-1.3l1.9-.7c.5-.2 1.1.1 1.3.6Z\"/></svg>";
const ICON_WIKI = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 7v14\"/><path d=\"M16 12h2M16 8h2\"/><path d=\"M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3Z\"/><path d=\"M21 18a1 1 0 0 0 1-1V4a1 1 0 0 0-1-1h-5a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3Z\"/></svg>";
const ICON_CARDS = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m12 2 9 5-9 5-9-5 9-5Z\"/><path d=\"m3 12 9 5 9-5M3 17l9 5 9-5\"/></svg>";
const ICON_ASK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M21 15a4 4 0 0 1-4 4H7l-4 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4Z\"/><path d=\"M8 8h8M8 12h5\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M5 12h14M13 6l6 6-6 6\"/></svg>";

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

    const now_secs = lib.time.nowSecs();
    var indexed_sources: usize = 0;
    var processing_sources: usize = 0;
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

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("workspace render failed");
    const sources_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("workspace render failed");
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("workspace render failed");
    const sync_action = lib.m3.demoHref(req.allocator, req, "/api/sync") catch return mer.internalError("workspace render failed");
    const partial = !modules_available or !announcements_available or !tasks_available or !sources_available or !pages_available or !decks_available;
    const notice_label: []const u8 = if (synced) "Sync started" else if (sync_failed) "Sync needs attention" else if (use_mock) "Illustrative workspace" else if (partial) "Partial availability" else "Live workspace";
    const notice_copy: []const u8 = if (synced) "New evidence will appear as indexing completes." else if (sync_failed) "The last confirmed workspace remains visible while sync is retried." else if (use_mock) "Synthetic fixtures show the complete study flow without using live workspace data." else if (partial) "Available study data is shown; unavailable sections are marked without synthetic fallback." else "Your connected sources and study evidence are up to date.";
    const notice_tone: []const u8 = if (sync_failed or partial) "warn" else if (use_mock) "info" else "good";

    w.print("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Your workspace</p><h1 class=\"cp-page-title\">Good afternoon.</h1></div><div class=\"cp-page-actions\"><a class=\"button button-dark button-small\" href=\"{s}\">Add source <span aria-hidden=\"true\">＋</span></a></div></header><div class=\"dashboard page-grid\">", .{sources_href}) catch return mer.internalError("workspace render failed");
    w.print("<div class=\"notice notice-{s}\" id=\"cp-dashboard-notice\"><div><span class=\"status-pill status-{s}\">{s}</span><span>{s}</span></div></div>", .{ notice_tone, notice_tone, notice_label, notice_copy }) catch return mer.internalError("workspace render failed");
    if (auth) |auth_state| {
        if (std.mem.eql(u8, auth_state, "registered") or std.mem.eql(u8, auth_state, "signed_in")) w.writeAll("<p class=\"cp-inline-status\" role=\"status\">Your account is ready.</p>") catch return mer.internalError("workspace render failed");
    }

    const hero_path: []const u8 = if (use_mock) "/wiki/immutable-lists" else if (live_pages.len > 0) std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{live_pages[0].slug}) catch "/wiki" else "/sources";
    const hero_href = lib.m3.demoHref(req.allocator, req, hero_path) catch return mer.internalError("workspace render failed");
    const hero_title: []const u8 = if (wiki_total > 0) "Continue the path from source to understanding." else "Build your first connected knowledge path.";
    const hero_copy: []const u8 = if (wiki_total > 0) "Your latest source evidence is ready to revisit in the knowledge wiki." else "Add a source, let WikiBase trace the evidence, then begin the first article.";
    w.print("<section class=\"dashboard-hero surface\"><div class=\"dashboard-hero-copy\"><p class=\"eyebrow\">Next useful step</p><h2>{s}</h2><p>{s}</p><div><a class=\"button button-dark\" href=\"{s}\">{s} {s}</a>", .{ hero_title, hero_copy, hero_href, if (wiki_total > 0) "Continue the article" else "Review sources", ICON_ARROW }) catch return mer.internalError("workspace render failed");
    if (session.isAuthenticated()) {
        w.print("<form action=\"{s}\" method=\"post\"><input type=\"hidden\" name=\"action\" value=\"sync\"><button class=\"button button-secondary\" type=\"submit\">Sync sources</button></form>", .{sync_action}) catch return mer.internalError("workspace render failed");
    }
    if (use_mock) {
        w.writeAll("</div></div><div class=\"knowledge-orbit\" aria-label=\"Illustrative knowledge completion 74 percent\"><svg viewBox=\"0 0 120 120\" role=\"img\"><circle cx=\"60\" cy=\"60\" r=\"48\" pathLength=\"100\"/><circle class=\"orbit-value\" cx=\"60\" cy=\"60\" r=\"48\" pathLength=\"100\" stroke-dasharray=\"74 100\"/></svg><strong>74%</strong><span>Illustrative</span></div></section>") catch return mer.internalError("workspace render failed");
    } else {
        w.writeAll("</div></div><div class=\"knowledge-orbit knowledge-orbit-unknown\" aria-label=\"Knowledge completion is not yet measured\"><svg viewBox=\"0 0 120 120\" role=\"img\"><circle cx=\"60\" cy=\"60\" r=\"48\" pathLength=\"100\"/></svg><strong>—</strong><span>Unmeasured</span></div></section>") catch return mer.internalError("workspace render failed");
    }

    w.writeAll("<section class=\"metric-grid\" aria-label=\"Workspace summary\">") catch return mer.internalError("workspace render failed");
    metricVisual(w, ICON_SOURCES, "sky", if (sources_available) indexed_sources else null, "Sources indexed", if (!sources_available) "Temporarily unavailable" else if (processing_sources > 0) "Imports still processing" else "Ready for retrieval") catch return mer.internalError("workspace render failed");
    metricVisual(w, ICON_WIKI, "moss", if (pages_available) wiki_total else null, "Wiki topics", if (pages_available) "Generated from evidence" else "Temporarily unavailable") catch return mer.internalError("workspace render failed");
    metricVisual(w, ICON_CARDS, "gold", if (decks_available) due_cards else null, "Cards due", if (decks_available) "Ready for review" else "Temporarily unavailable") catch return mer.internalError("workspace render failed");
    metricVisual(w, ICON_ASK, "rose", null, "Cited questions", "Measured after grounded answers") catch return mer.internalError("workspace render failed");
    w.writeAll("</section><div class=\"dashboard-columns\"><section><div class=\"section-title\"><div><h2>Active modules</h2><p>Where your knowledge is taking shape.</p></div><a href=\"") catch return mer.internalError("workspace render failed");
    w.writeAll(wiki_href) catch return mer.internalError("workspace render failed");
    w.writeAll("\">Open wiki</a></div><div class=\"module-list surface\">") catch return mer.internalError("workspace render failed");
    if (modules_slice.len == 0) {
        w.writeAll("<div class=\"cp-empty\">No workspace modules are available yet.</div>") catch return mer.internalError("workspace render failed");
    } else for (modules_slice, 0..) |module, index| {
        const module_href_raw = std.fmt.allocPrint(req.allocator, "/wiki?module={s}", .{module.code}) catch "/wiki";
        const module_href = lib.m3.demoHref(req.allocator, req, module_href_raw) catch wiki_href;
        const color: []const u8 = switch (index % 3) {
            0 => "blue",
            1 => "green",
            else => "ochre",
        };
        const initials = if (module.code.len >= 2) module.code[0..2] else module.code;
        w.print("<a href=\"{s}\"><span class=\"module-code {s}\">{s}</span><div><strong>{s}</strong><small>{s}</small><div class=\"slim-progress {s}\"><i{s}></i></div></div><b>{s}</b></a>", .{ module_href, color, lib.ui.escapeSafe(req.allocator, initials), lib.ui.escapeSafe(req.allocator, module.code), lib.ui.escapeSafe(req.allocator, module.name), if (use_mock) "" else "is-unknown", if (use_mock) " style=\"width:74%\"" else "", if (use_mock) "74%" else "—" }) catch return mer.internalError("workspace render failed");
    }
    w.print("</div></section><section><div class=\"section-title\"><div><h2>Recent evidence</h2><p>Latest activity across the workspace.</p></div><a href=\"{s}\">All sources</a></div><div class=\"activity-list surface\">", .{sources_href}) catch return mer.internalError("workspace render failed");
    if (use_mock and lib.mock.sources.len > 0) {
        const source = lib.mock.sources[0];
        activityVisual(req, w, ICON_SOURCES, source.title, "Source indexed and ready for cited study.", source.updated_at, now_secs) catch return mer.internalError("workspace render failed");
    } else if (live_sources.len > 0) {
        const source = live_sources[0];
        activityVisual(req, w, ICON_SOURCES, source.title, "Source library record updated.", source.updated_at, now_secs) catch return mer.internalError("workspace render failed");
    }
    if (!use_mock and live_pages.len > 0) {
        const page = live_pages[0];
        activityVisual(req, w, ICON_WIKI, page.title, if (page.summary.len > 0) page.summary else "Generated wiki page available from live evidence.", page.updated_at, now_secs) catch return mer.internalError("workspace render failed");
    }
    if (announcements_slice.len > 0) {
        const announcement = announcements_slice[0];
        activityVisual(req, w, ICON_ASK, announcement.title, announcement.summary orelse announcement.content, announcement.posted_at, now_secs) catch return mer.internalError("workspace render failed");
    } else if (tasks_slice.len > 0) {
        const task = tasks_slice[0];
        activityVisual(req, w, ICON_ASK, task.title, "Study task available from the connected workspace.", task.due_at orelse "", now_secs) catch return mer.internalError("workspace render failed");
    }
    if (decks_available and card_total > 0) {
        var due_text_buf = lib.ui.buildHtml(req.allocator);
        due_text_buf.writer.print("{d} cards are ready for evidence-backed review.", .{due_cards}) catch {};
        activityVisual(req, w, ICON_CARDS, "Flashcards ready", due_text_buf.written(), "", now_secs) catch return mer.internalError("workspace render failed");
    }
    if ((use_mock and lib.mock.sources.len == 0) or (!use_mock and live_sources.len == 0 and announcements_slice.len == 0 and card_total == 0)) {
        w.writeAll("<div class=\"cp-empty\">Recent evidence will appear after the first source is indexed.</div>") catch return mer.internalError("workspace render failed");
    }
    w.writeAll("</div></section></div></div>") catch return mer.internalError("workspace render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn metricVisual(w: *std.Io.Writer, icon: []const u8, tone: []const u8, value: ?usize, label: []const u8, note: []const u8) !void {
    try w.print("<article class=\"surface\"><span class=\"metric-icon {s}\">{s}</span><div>", .{ tone, icon });
    if (value) |number| try w.print("<strong>{d}</strong>", .{number}) else try w.writeAll("<strong>—</strong>");
    try w.print("<span>{s}</span></div><small>{s}</small></article>", .{ label, note });
}

fn activityVisual(req: mer.Request, w: *std.Io.Writer, icon: []const u8, title: []const u8, copy: []const u8, timestamp: []const u8, now_secs: i64) !void {
    const when = if (timestamp.len > 0) lib.time.formatRelative(req.allocator, timestamp, now_secs) catch timestamp else "Now";
    try w.print("<article><span class=\"activity-mark\">{s}</span><div><strong>{s}</strong><p>{s}</p><small>{s}</small></div></article>", .{ icon, lib.ui.escapeSafe(req.allocator, title), lib.ui.escapeSafe(req.allocator, copy), lib.ui.escapeSafe(req.allocator, when) });
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
    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("workspace render failed");
    }
    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <p class="cp-page-kicker">
    ) catch return mer.internalError("workspace render failed");
    if (demo) w.writeAll("Synthetic demo · ") catch return mer.internalError("workspace render failed");
    w.writeAll(
        \\Empty workspace
        \\    </p><h1 class="cp-page-title">Workspace</h1>
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
