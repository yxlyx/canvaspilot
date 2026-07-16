// app/dashboard.zig — Milestone 2 workspace overview.
//
// Repurposes the M1 module dashboard into the prototype workspace home: source
// coverage, generated wiki pages, Q&A readiness, and flashcard practice state.
// Backend endpoints for M2 metadata are still landing, so this page combines
// authenticated module data with stable workspace fixture records.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Workspace",
    .description = "WikiBase workspace overview for sources, wiki pages, Q&A, and flashcards.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const explicit_demo = lib.m3.isExplicitDemo(req);
    const use_mock = explicit_demo or !session.isAuthenticated();
    const synced = req.queryParam("synced") != null;
    const sync_failed = req.queryParam("sync_failed") != null;
    const auth = req.queryParam("auth");

    var modules_slice: []const lib.types.Module = lib.mock.modules;
    var announcements_slice: []const lib.types.Announcement = lib.mock.announcements;
    var tasks_slice: []const lib.types.Task = lib.mock.tasks;
    var backend_ok = true;
    var using_live_modules = false;
    var using_live_announcements = false;
    var using_live_tasks = false;
    var using_live_sources = false;
    var using_live_wiki = false;
    var using_live_decks = false;

    if (!use_mock) {
        const mods = lib.backend.listModules(req.allocator, session.token);
        if (mods.value) |v| {
            if (v.value.len > 0) {
                modules_slice = v.value;
                using_live_modules = true;
            } else {
                backend_ok = false;
            }
        } else {
            backend_ok = false;
        }

        if (using_live_modules) {
            const first = modules_slice[0];
            const anns = lib.backend.moduleAnnouncements(req.allocator, session.token, first.id);
            if (anns.value) |v| {
                announcements_slice = v.value;
                using_live_announcements = true;
            } else backend_ok = false;
            const upcoming = lib.backend.upcomingTasks(req.allocator, session.token);
            if (upcoming.value) |v| {
                tasks_slice = v.value;
                using_live_tasks = true;
            } else backend_ok = false;
        }
    }

    if (modules_slice.len == 0) {
        return renderEmpty(req);
    }

    const focus = modules_slice[0];
    const now_secs = lib.time.nowSecs();
    var indexed_sources: usize = 0;
    var processing_sources: usize = 0;
    var total_chunks: usize = 0;
    if (use_mock) {
        for (lib.mock.sources) |source| {
            if (std.mem.eql(u8, source.status, "indexed")) indexed_sources += 1;
            if (std.mem.eql(u8, source.status, "processing")) processing_sources += 1;
            total_chunks += source.chunk_count;
        }
    }

    var queued_cards: usize = 0;
    if (use_mock) {
        for (lib.mock.decks) |deck| queued_cards += deck.due_count;
    }

    var source_total = lib.mock.sources.len;
    var wiki_total = lib.mock.wiki_pages.len;
    var card_total = lib.mock.flashcards.len;
    if (!use_mock) {
        const sources = lib.backend.listSources(req.allocator, session.token);
        if (sources.value) |parsed_sources| {
            using_live_sources = true;
            source_total = parsed_sources.value.len;
            indexed_sources = 0;
            processing_sources = 0;
            for (parsed_sources.value) |source| {
                if (std.mem.eql(u8, source.status, "ready")) indexed_sources += 1;
                if (std.mem.eql(u8, source.status, "pending") or std.mem.eql(u8, source.status, "indexing")) processing_sources += 1;
            }
        } else {
            backend_ok = false;
        }

        const wiki_pages = lib.backend.listWikiPages(req.allocator, session.token);
        if (wiki_pages.value) |parsed_pages| {
            using_live_wiki = true;
            wiki_total = 0;
            for (parsed_pages.value) |page| {
                if (!std.mem.eql(u8, page.page_type, "index")) wiki_total += 1;
            }
        } else {
            backend_ok = false;
        }

        const decks = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (decks.value) |parsed_decks| {
            using_live_decks = true;
            queued_cards = 0;
            card_total = 0;
            for (parsed_decks.value) |deck| {
                queued_cards += deck.cards.len;
                card_total += deck.card_count;
            }
        } else {
            backend_ok = false;
        }
    }

    var open_tasks: usize = 0;
    for (tasks_slice) |task| {
        if (!task.completed) open_tasks += 1;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("workspace render failed");
    const sources_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("workspace render failed");
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("workspace render failed");
    const flashcards_href = lib.m3.demoHref(req.allocator, req, "/flashcards") catch return mer.internalError("workspace render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, "/chat") catch return mer.internalError("workspace render failed");
    const focus_data_label: []const u8 = if (using_live_modules) "live module" else "synthetic fixture";
    const announcements_data_label: []const u8 = if (using_live_announcements) "live data" else "synthetic fixtures";

    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("workspace render failed");
    }

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Workspace</h1>
    ) catch return mer.internalError("workspace render failed");

    if (use_mock) {
        w.writeAll("    <div class=\"cp-page-sub\">Showing prototype fixture data — sign in to connect a real workspace.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (!backend_ok) {
        w.writeAll("    <div class=\"cp-page-sub\">Backend metadata is incomplete. Unavailable live counts are marked; synthetic preview sections are explicitly labelled.</div>\n") catch return mer.internalError("workspace render failed");
    } else {
        const last_synced = focus.last_synced_at orelse "—";
        const when = lib.time.formatRelative(req.allocator, last_synced, now_secs) catch "—";
        w.print("    <div class=\"cp-page-sub\">Last synced {s}. Live backend metadata is shown where available; synthetic preview sections below are explicitly labelled.</div>\n", .{when}) catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Review sources</a>
    , .{sources_href}) catch return mer.internalError("workspace render failed");
    if (session.isAuthenticated() and !explicit_demo) {
        w.writeAll(
            \\    <form action="/api/sync" method="post" class="cp-logout">
            \\      <input type="hidden" name="action" value="sync">
            \\      <button type="submit" class="cp-btn cp-btn-primary">Sync now</button>
            \\    </form>
        ) catch return mer.internalError("workspace render failed");
    } else if (explicit_demo) {
        w.writeAll("    <div class=\"cp-disabled-action\"><button type=\"button\" class=\"cp-btn cp-btn-primary\" aria-disabled=\"true\" aria-describedby=\"demo-sync-note\">Sync unavailable</button><small id=\"demo-sync-note\">Demo mode never starts a live workspace sync.</small></div>\n") catch return mer.internalError("workspace render failed");
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
        w.writeAll("<div class=\"cp-status-banner cp-status-error\">Sync failed. Live metadata may be incomplete; synthetic preview sections remain labelled.</div>\n") catch return mer.internalError("workspace render failed");
    } else if (auth) |auth_state| {
        if (std.mem.eql(u8, auth_state, "registered")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Account created. Live metadata is shown when available; synthetic previews are labelled.</div>\n") catch return mer.internalError("workspace render failed");
        } else if (std.mem.eql(u8, auth_state, "signed_in")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Signed in. Live metadata is shown when available; synthetic previews are labelled.</div>\n") catch return mer.internalError("workspace render failed");
        }
    }

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("workspace render failed");
    if (use_mock or using_live_sources) {
        metricCard(w, "Sources ready", indexed_sources, source_total, "Source library", sources_href) catch return mer.internalError("workspace render failed");
    } else {
        metricUnavailable(w, "Sources ready", "Source library", sources_href) catch return mer.internalError("workspace render failed");
    }
    if (use_mock or using_live_wiki) {
        metricCard(w, "Wiki pages", wiki_total, wiki_total, "Generated wiki", wiki_href) catch return mer.internalError("workspace render failed");
    } else {
        metricUnavailable(w, "Wiki pages", "Generated wiki", wiki_href) catch return mer.internalError("workspace render failed");
    }
    if (use_mock) {
        metricCard(w, "Due cards", queued_cards, card_total, "Flashcards", flashcards_href) catch return mer.internalError("workspace render failed");
    } else if (using_live_decks) {
        metricCard(w, "Available cards", queued_cards, card_total, "Flashcards", flashcards_href) catch return mer.internalError("workspace render failed");
    } else {
        metricUnavailable(w, "Available cards", "Flashcards", flashcards_href) catch return mer.internalError("workspace render failed");
    }
    if (use_mock or using_live_tasks) {
        metricCard(w, "Open tasks", open_tasks, tasks_slice.len, "Ask in chat", chat_href) catch return mer.internalError("workspace render failed");
    } else {
        metricUnavailable(w, "Open tasks", "Ask in chat", chat_href) catch return mer.internalError("workspace render failed");
    }
    w.writeAll("</section>\n") catch return mer.internalError("workspace render failed");

    w.print(
        \\<div class="cp-grid">
        \\<div>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Workspace focus</span><span>{s}</span></div>
    , .{focus_data_label}) catch return mer.internalError("workspace render failed");

    const safe_code = lib.ui.escapeSafe(req.allocator, focus.code);
    const safe_name = lib.ui.escapeSafe(req.allocator, focus.name);
    const safe_term = lib.ui.escapeSafe(req.allocator, focus.term);
    w.print(
        \\    <div class="cp-module-summary">
        \\      <div class="cp-module-code">{s}</div>
        \\      <div class="cp-module-name">{s}</div>
    , .{ safe_code, safe_name }) catch return mer.internalError("workspace render failed");
    if (use_mock) {
        w.print("      <div class=\"cp-module-meta\">{s} · {d} synthetic source records · {d} synthetic chunks</div>\n", .{ safe_term, source_total, total_chunks }) catch return mer.internalError("workspace render failed");
    } else if (using_live_sources) {
        w.print("      <div class=\"cp-module-meta\">{s} · {d} live source records · dashboard chunk total unavailable</div>\n", .{ safe_term, source_total }) catch return mer.internalError("workspace render failed");
    } else {
        w.print("      <div class=\"cp-module-meta\">{s} · dashboard source and chunk totals unavailable</div>\n", .{safe_term}) catch return mer.internalError("workspace render failed");
    }
    w.writeAll(
        \\    </div>
        \\  </section>
    ) catch return mer.internalError("workspace render failed");

    w.print(
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Source library preview</span><span>synthetic fixtures · <a href="{s}">View all</a></span></div>
        \\    <div class="cp-source-list">
    , .{sources_href}) catch return mer.internalError("workspace render failed");

    for (lib.mock.sources, 0..) |source, idx| {
        if (idx >= 3) break;
        renderSourcePreview(req, w, source, now_secs) catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\    </div>
        \\  </section>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Recent announcements</span><span>{s}</span></div>
        \\    <ul class="cp-feed">
    , .{announcements_data_label}) catch return mer.internalError("workspace render failed");

    var ann_shown: usize = 0;
    for (announcements_slice) |a| {
        if (!std.mem.eql(u8, a.module_id, focus.id)) continue;
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
    }
    if (ann_shown == 0) {
        w.writeAll("      <li class=\"cp-empty\">No announcements indexed yet.</li>\n") catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\    </ul>
        \\  </section>
        \\</div>
        \\<div>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Generated wiki</span><span>synthetic fixtures · <a href="{s}">View all</a></span></div>
        \\    <div class="cp-wiki-list">
    , .{wiki_href}) catch return mer.internalError("workspace render failed");

    for (lib.mock.wiki_pages) |page| {
        const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
        const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
        const href = std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{page.slug}) catch "/wiki/immutable-lists";
        const page_href = lib.m3.demoHref(req.allocator, req, href) catch return mer.internalError("workspace render failed");
        w.print(
            \\      <a class="cp-wiki-row" href="{s}">
            \\        <span>{s}</span>
            \\        <small>{s}</small>
            \\      </a>
        , .{ page_href, safe_title, safe_summary }) catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\    </div>
        \\  </section>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Flashcard practice</span><span>synthetic fixture · <a href="{s}">Practice</a></span></div>
    , .{flashcards_href}) catch return mer.internalError("workspace render failed");

    if (lib.mock.decks.len > 0) {
        const deck = lib.mock.decks[0];
        const safe_title = lib.ui.escapeSafe(req.allocator, deck.title);
        const safe_desc = lib.ui.escapeSafe(req.allocator, deck.description);
        const deck_path = std.fmt.allocPrint(req.allocator, "/flashcards?deck={s}", .{deck.id}) catch "/flashcards";
        const deck_href = lib.m3.demoHref(req.allocator, req, deck_path) catch return mer.internalError("workspace render failed");
        w.print(
            \\    <div class="cp-study-card">
            \\      <div class="cp-study-title">{s}</div>
            \\      <p>{s}</p>
            \\      <div class="cp-module-meta">{d} due · {d} cards total</div>
            \\      <a class="cp-btn cp-btn-primary" href="{s}">Start review</a>
            \\    </div>
        , .{ safe_title, safe_desc, deck.due_count, deck.card_count, deck_href }) catch return mer.internalError("workspace render failed");
    }

    w.print(
        \\  </section>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Ask WikiBase</span></div>
        \\    <p class="cp-muted-copy">Use cited Q&amp;A across the indexed source set, then jump back to the exact source or wiki page.</p>
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Open Q&amp;A</a>
        \\  </section>
        \\</div>
        \\</div>
    , .{chat_href}) catch return mer.internalError("workspace render failed");

    if (processing_sources > 0) {
        w.print("<div class=\"cp-status-banner cp-status-warn\" style=\"margin-top:16px\">{d} source import is still processing; the source library shows the loading state.</div>\n", .{processing_sources}) catch return mer.internalError("workspace render failed");
    }

    return lib.ui.htmlResponse(&buf);
}

fn metricCard(
    w: *std.Io.Writer,
    label: []const u8,
    value: usize,
    sub_value: usize,
    action: []const u8,
    href: []const u8,
) !void {
    try w.print(
        \\  <a class="cp-metric-card" href="{s}">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">{d}</span>
        \\    <span class="cp-metric-sub">{d} total · {s}</span>
        \\  </a>
    , .{ href, label, value, sub_value, action });
}

fn metricUnavailable(w: *std.Io.Writer, label: []const u8, action: []const u8, href: []const u8) !void {
    try w.print(
        \\  <a class="cp-metric-card" href="{s}">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">Unavailable</span>
        \\    <span class="cp-metric-sub">Live backend count · {s}</span>
        \\  </a>
    , .{ href, label, action });
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

fn sourceStatusClass(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "indexed")) return "cp-source-status cp-source-status-indexed";
    if (std.mem.eql(u8, status, "needs review")) return "cp-source-status cp-source-status-review";
    if (std.mem.eql(u8, status, "processing")) return "cp-source-status cp-source-status-processing";
    return "cp-source-status";
}

fn renderEmpty(req: mer.Request) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const session = lib.session.fromRequest(req);
    lib.m3.demoMarker(req, w) catch return mer.internalError("workspace render failed");
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
    w.writeAll(
        \\</header>
        \\<section class="cp-card">
        \\  <div class="cp-empty">
        \\    Sign in, then sync once source import is configured. Or open
        \\    the prototype with <a href="/dashboard?mock=1">fixture data</a>.
        \\  </div>
        \\</section>
    ) catch return mer.internalError("workspace render failed");
    return lib.ui.htmlResponse(&buf);
}
