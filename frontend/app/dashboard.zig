const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const SECS_PER_DAY: i64 = 24 * 60 * 60;
const UPCOMING_WINDOW_SECS: i64 = 14 * SECS_PER_DAY;

pub const meta: mer.Meta = .{
    .title = "Dashboard",
    .description = "Workspace summary, source-backed study flow, and upcoming work.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    const synced = req.queryParam("synced") != null;
    const sync_failed = req.queryParam("sync_failed") != null;
    const auth = req.queryParam("auth");

    var modules_slice: []const lib.types.Module = lib.mock.modules;
    var announcements_slice: []const lib.types.Announcement = lib.mock.announcements;
    var tasks_slice: []const lib.types.Task = lib.mock.tasks;
    var backend_ok = true;

    if (!use_mock) {
        const mods = lib.backend.listModules(req.allocator, session.token);
        if (mods.value) |v| modules_slice = v.value else backend_ok = false;

        if (modules_slice.len > 0) {
            const first = modules_slice[0];
            const anns = lib.backend.moduleAnnouncements(req.allocator, session.token, first.id);
            if (anns.value) |v| announcements_slice = v.value else backend_ok = false;
            const upcoming = lib.backend.upcomingTasks(req.allocator, session.token);
            if (upcoming.value) |v| tasks_slice = v.value else backend_ok = false;
        }
    }

    if (modules_slice.len == 0) {
        return renderEmpty(req, use_mock, backend_ok);
    }

    const focus = modules_slice[0];
    const now_secs = lib.time.nowSecs();
    var ann_count: usize = 0;
    for (announcements_slice) |a| {
        if (std.mem.eql(u8, a.module_id, focus.id)) ann_count += 1;
    }
    var task_count: usize = 0;
    for (tasks_slice) |t| {
        if (!std.mem.eql(u8, t.module_id, focus.id)) continue;
        if (t.completed) continue;
        const due_iso = t.due_at orelse continue;
        if (!isUpcoming(due_iso, now_secs)) continue;
        task_count += 1;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("dashboard render failed");
    }

    const safe_code = lib.ui.escape(req.allocator, focus.code) catch focus.code;
    const safe_name = lib.ui.escape(req.allocator, focus.name) catch focus.name;
    const safe_term = lib.ui.escape(req.allocator, focus.term) catch focus.term;

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <div class="cp-page-kicker">Workspace overview</div>
        \\    <div class="cp-page-title">Dashboard</div>
        \\
    ) catch return mer.internalError("dashboard render failed");

    if (use_mock) {
        w.writeAll("    <div class=\"cp-page-sub\">Showing demo data — sign in to see your real workspace.</div>\n") catch return mer.internalError("dashboard render failed");
    } else if (!backend_ok) {
        w.writeAll("    <div class=\"cp-page-sub\">Backend unreachable — showing fallback workspace data.</div>\n") catch return mer.internalError("dashboard render failed");
    } else {
        const last_synced = focus.last_synced_at orelse "—";
        const when = lib.time.formatRelative(req.allocator, last_synced, now_secs) catch last_synced;
        w.print("    <div class=\"cp-page-sub\">Last synced {s}.</div>\n", .{when}) catch return mer.internalError("dashboard render failed");
    }

    w.writeAll("  </div>\n") catch return mer.internalError("dashboard render failed");
    if (session.isAuthenticated()) {
        w.writeAll(
            \\  <form action="/api/sync" method="post" class="cp-logout">
            \\    <input type="hidden" name="action" value="sync">
            \\    <button type="submit" class="cp-btn cp-btn-primary">Sync now</button>
            \\  </form>
            \\
        ) catch return mer.internalError("dashboard render failed");
    } else {
        w.writeAll("  <a class=\"cp-btn cp-btn-primary\" href=\"/login\">Sign in to sync</a>\n") catch return mer.internalError("dashboard render failed");
    }
    w.writeAll("</header>\n") catch return mer.internalError("dashboard render failed");

    if (synced) {
        w.writeAll("<div class=\"cp-status-banner cp-status-info\">Sync started. Refresh in a moment to see the latest.</div>\n") catch return mer.internalError("dashboard render failed");
    } else if (sync_failed) {
        w.writeAll("<div class=\"cp-status-banner cp-status-error\">Sync failed. Check the backend logs and try again.</div>\n") catch return mer.internalError("dashboard render failed");
    } else if (auth) |auth_state| {
        if (std.mem.eql(u8, auth_state, "registered")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Account created. Showing demo module data.</div>\n") catch return mer.internalError("dashboard render failed");
        } else if (std.mem.eql(u8, auth_state, "signed_in")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Signed in. Showing demo module data.</div>\n") catch return mer.internalError("dashboard render failed");
        }
    }

    w.print(
        \\<section class="cp-dashboard-hero">
        \\  <div class="cp-course-code">{s}</div>
        \\  <h1 class="cp-dashboard-title">{s}</h1>
        \\  <p class="cp-dashboard-sub">A course workspace for source review, generated notes, cited Q&amp;A, and practice.</p>
        \\  <div class="cp-dashboard-meta">
        \\    <span class="cp-chip">{s}</span>
        \\    <span class="cp-chip">{d} synced module{s}</span>
        \\    <span class="cp-chip">{d} announcement{s}</span>
        \\    <span class="cp-chip">{d} upcoming task{s}</span>
        \\  </div>
        \\</section>
        \\
    , .{
        safe_code,
        safe_name,
        safe_term,
        modules_slice.len,
        if (modules_slice.len == 1) "" else "s",
        ann_count,
        if (ann_count == 1) "" else "s",
        task_count,
        if (task_count == 1) "" else "s",
    }) catch return mer.internalError("dashboard render failed");

    w.print(
        \\<section class="cp-stat-grid" aria-label="Workspace status">
        \\  <div class="cp-stat-card"><div class="cp-stat-value">{d}</div><div class="cp-stat-label">Synced modules</div></div>
        \\  <div class="cp-stat-card"><div class="cp-stat-value">{d}</div><div class="cp-stat-label">Recent updates</div></div>
        \\  <div class="cp-stat-card"><div class="cp-stat-value">{d}</div><div class="cp-stat-label">Due soon</div></div>
        \\</section>
        \\
    , .{ modules_slice.len, ann_count, task_count }) catch return mer.internalError("dashboard render failed");

    w.writeAll(
        \\<div class="cp-grid">
        \\<div>
        \\
    ) catch return mer.internalError("dashboard render failed");

    w.print(
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Course focus</span><span>{d} synced</span></div>
        \\    <div class="cp-module-summary">
        \\      <div class="cp-module-code">{s}</div>
        \\      <div class="cp-module-name">{s}</div>
        \\      <div class="cp-module-meta">{s}</div>
        \\    </div>
        \\  </section>
        \\
    , .{ modules_slice.len, safe_code, safe_name, safe_term }) catch return mer.internalError("dashboard render failed");

    w.writeAll(
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Recent announcements</span><span>source feed</span></div>
        \\    <ul class="cp-feed">
        \\
    ) catch return mer.internalError("dashboard render failed");

    var ann_shown: usize = 0;
    for (announcements_slice) |a| {
        if (!std.mem.eql(u8, a.module_id, focus.id)) continue;
        if (ann_shown >= 5) break;
        ann_shown += 1;
        const safe_title = lib.ui.escape(req.allocator, a.title) catch a.title;
        const summary = a.summary orelse a.content;
        const safe_summary = lib.ui.escape(req.allocator, summary) catch summary;
        const when = lib.time.formatRelative(req.allocator, a.posted_at, now_secs) catch "—";
        w.print(
            \\      <li class="cp-feed-item">
            \\        <div class="cp-feed-title">{s}</div>
            \\        <div class="cp-feed-meta">{s}</div>
            \\        <div class="cp-feed-body">{s}</div>
            \\      </li>
            \\
        , .{ safe_title, when, safe_summary }) catch return mer.internalError("dashboard render failed");
    }
    if (ann_shown == 0) {
        w.writeAll("      <li class=\"cp-empty\">No announcements for this module yet.</li>\n") catch return mer.internalError("dashboard render failed");
    }
    w.writeAll(
        \\    </ul>
        \\  </section>
        \\</div>
        \\<div>
        \\
    ) catch return mer.internalError("dashboard render failed");

    w.writeAll(
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Upcoming assignments</span><span>next 14 days</span></div>
        \\    <ul class="cp-task-list">
        \\
    ) catch return mer.internalError("dashboard render failed");

    var task_shown: usize = 0;
    for (tasks_slice) |t| {
        if (!std.mem.eql(u8, t.module_id, focus.id)) continue;
        if (t.completed) continue;
        const due_iso = t.due_at orelse continue;
        if (!isUpcoming(due_iso, now_secs)) continue;
        if (task_shown >= 6) break;
        task_shown += 1;
        const safe_title = lib.ui.escape(req.allocator, t.title) catch t.title;
        const when = lib.time.formatRelative(req.allocator, due_iso, now_secs) catch "—";
        const urgent = lib.time.isUrgent(due_iso, now_secs);
        const due_cls: []const u8 = if (urgent) "cp-task-due cp-task-due-urgent" else "cp-task-due";
        w.print(
            \\      <li class="cp-task">
            \\        <div>
            \\          <div class="cp-task-title">{s}</div>
            \\          <div class="cp-task-meta">{s}</div>
            \\        </div>
            \\        <span class="{s}">{s}</span>
            \\      </li>
            \\
        , .{ safe_title, t.task_type, due_cls, when }) catch return mer.internalError("dashboard render failed");
    }
    if (task_shown == 0) {
        w.writeAll("      <li class=\"cp-empty\">Nothing due for this module in the next two weeks.</li>\n") catch return mer.internalError("dashboard render failed");
    }

    w.writeAll(
        \\    </ul>
        \\  </section>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Ask WikiBase</span><span>cited Q&amp;A</span></div>
        \\    <p style="font-size:13.5px;color:var(--cp-muted);margin-bottom:14px">
        \\      Ask anything about this module. Answers stay grounded in course material and show sources inline.
        \\    </p>
        \\    <a class="cp-btn cp-btn-primary" href="/chat">Open chat</a>
        \\  </section>
        \\</div>
        \\</div>
        \\
    ) catch return mer.internalError("dashboard render failed");

    w.print(
        \\<section class="cp-stat-grid" aria-label="Workspace sections" style="margin-top:18px">
        \\  <div class="cp-card">
        \\    <div class="cp-card-title"><span>Source library</span><span>{d} sources</span></div>
        \\    <p class="cp-muted-copy">Imported documents, links, and notes chunked for cited answers.</p>
        \\    <a class="cp-btn cp-btn-ghost" href="/sources">Review sources</a>
        \\  </div>
        \\  <div class="cp-card">
        \\    <div class="cp-card-title"><span>Generated wiki</span><span>{d} pages</span></div>
        \\    <p class="cp-muted-copy">Study pages compiled from your sources, with citations and backlinks.</p>
        \\    <a class="cp-btn cp-btn-ghost" href="/wiki">Open wiki</a>
        \\  </div>
        \\  <div class="cp-card">
        \\    <div class="cp-card-title"><span>Flashcards</span><span>{d} decks</span></div>
        \\    <p class="cp-muted-copy">Practice decks generated from wiki pages to track weak topics.</p>
        \\    <a class="cp-btn cp-btn-ghost" href="/flashcards">Practice now</a>
        \\  </div>
        \\</section>
        \\
    , .{ lib.mock.sources.len, lib.mock.wiki_pages.len, lib.mock.decks.len }) catch return mer.internalError("dashboard render failed");

    return lib.ui.htmlResponse(&buf);
}

fn isUpcoming(iso: []const u8, now_secs: i64) bool {
    const due_secs = lib.time.parseIsoSecs(iso) orelse return true;
    const delta = due_secs - now_secs;
    return delta >= 0 and delta <= UPCOMING_WINDOW_SECS;
}

fn renderEmpty(req: mer.Request, use_mock: bool, backend_ok: bool) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    _ = use_mock;
    _ = backend_ok;
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("dashboard render failed");
    }
    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <div class="cp-page-kicker">Workspace overview</div>
        \\    <div class="cp-page-title">Dashboard</div>
        \\    <div class="cp-page-sub">No modules synced yet.</div>
        \\  </div>
        \\
    ) catch return mer.internalError("dashboard render failed");
    if (session.isAuthenticated()) {
        w.writeAll(
            \\  <form action="/api/sync" method="post" class="cp-logout">
            \\    <input type="hidden" name="action" value="sync">
            \\    <button type="submit" class="cp-btn cp-btn-primary">Sync now</button>
            \\  </form>
            \\
        ) catch return mer.internalError("dashboard render failed");
    } else {
        w.writeAll("  <a class=\"cp-btn cp-btn-primary\" href=\"/login\">Sign in to sync</a>\n") catch return mer.internalError("dashboard render failed");
    }
    w.writeAll(
        \\</header>
        \\<section class="cp-card">
        \\  <div class="cp-empty">
        \\    Sign in, then hit <em>Sync now</em> once module import is configured. Or open
        \\    the demo with <a href="/dashboard?mock=1">mock data</a>.
        \\  </div>
        \\</section>
        \\
    ) catch return mer.internalError("dashboard render failed");
    return lib.ui.htmlResponse(&buf);
}
