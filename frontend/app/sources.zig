// app/sources.zig — Milestone 2 source library prototype.
//
// Shows imported workspace sources that power Q&A, generated wiki pages, and
// flashcard decks. Live sessions use backend metadata; fixtures are available
// only through the explicit demo gate.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sources",
    .description = "Review imported workspace sources and indexing state.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const use_mock = lib.m3.isExplicitDemo(req);
    const raw_filter_type = req.queryParam("type") orelse "";
    const raw_filter_status = req.queryParam("status") orelse "";
    const filter_type = lib.form.decode(req.allocator, raw_filter_type) catch raw_filter_type;
    const filter_status = lib.form.decode(req.allocator, raw_filter_status) catch raw_filter_status;
    const now_secs = lib.time.nowSecs();

    var live_sources: ?[]const lib.types.SourceResponse = null;
    if (!use_mock) {
        const result = lib.backend.listSources(req.allocator, session.token);
        if (result.value) |parsed_sources| {
            live_sources = parsed_sources.value;
        } else {
            return lib.m3.liveError(req, "Source library", result.status);
        }
    }

    var total_chunks: usize = 0;
    var ready_count: usize = 0;
    var review_count: usize = 0;
    var processing_count: usize = 0;
    if (live_sources) |sources| {
        for (sources) |source| {
            if (std.mem.eql(u8, source.status, "ready")) ready_count += 1;
            if (std.mem.eql(u8, source.status, "failed") or std.mem.eql(u8, source.status, "archived")) review_count += 1;
            if (std.mem.eql(u8, source.status, "pending") or std.mem.eql(u8, source.status, "indexing")) processing_count += 1;
        }
    } else {
        for (lib.mock.sources) |source| {
            total_chunks += source.chunk_count;
            if (std.mem.eql(u8, source.status, "indexed")) ready_count += 1;
            if (std.mem.eql(u8, source.status, "needs review")) review_count += 1;
            if (std.mem.eql(u8, source.status, "processing")) processing_count += 1;
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoBanner(req, w) catch return mer.internalError("sources render failed");

    const dashboard_href = lib.m3.demoHref(req.allocator, req, "/dashboard") catch return mer.internalError("sources render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, "/chat") catch return mer.internalError("sources render failed");
    w.print(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Source library</h1>
        \\    <div class="cp-page-sub">Track what has been imported, chunked, and made available for cited answers.</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Workspace</a>
        \\    <a class="cp-btn cp-btn-primary" href="{s}">Ask with sources</a>
        \\  </div>
        \\</header>
    , .{ dashboard_href, chat_href }) catch return mer.internalError("sources render failed");

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("sources render failed");
    metricCard(w, "Ready", ready_count, "available for Q&A") catch return mer.internalError("sources render failed");
    metricCard(w, "Needs review", review_count, "failed or archived") catch return mer.internalError("sources render failed");
    metricCard(w, "Processing", processing_count, "pending import") catch return mer.internalError("sources render failed");
    metricCard(w, "Chunks", total_chunks, if (use_mock) "synthetic fixture total" else "not reported by source metadata") catch return mer.internalError("sources render failed");
    w.writeAll("</section>\n") catch return mer.internalError("sources render failed");

    if (filter_type.len > 0 or filter_status.len > 0) {
        const clear_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("sources render failed");
        w.print("<div class=\"cp-status-banner cp-status-info\">Filtered source view. <a href=\"{s}\">Clear filters</a></div>\n", .{clear_href}) catch return mer.internalError("sources render failed");
    }

    w.writeAll(
        \\<section class="cp-card">
        \\  <div class="cp-card-title"><span>Import queue</span><span>metadata</span></div>
        \\  <fieldset class="cp-filter-row" aria-label="Source filters">
    ) catch return mer.internalError("sources render failed");

    filterChip(req, w, "All", "/sources", filter_type.len == 0 and filter_status.len == 0) catch return mer.internalError("sources render failed");
    filterChip(req, w, "Ready", "/sources?status=ready", std.mem.eql(u8, filter_status, "ready")) catch return mer.internalError("sources render failed");
    filterChip(req, w, "Indexing", "/sources?status=indexing", std.mem.eql(u8, filter_status, "indexing")) catch return mer.internalError("sources render failed");
    filterChip(req, w, "Pending", "/sources?status=pending", std.mem.eql(u8, filter_status, "pending")) catch return mer.internalError("sources render failed");
    filterChip(req, w, "Review", "/sources?status=failed", std.mem.eql(u8, filter_status, "failed")) catch return mer.internalError("sources render failed");
    filterChip(req, w, "Markdown", "/sources?type=markdown", std.mem.eql(u8, filter_type, "markdown")) catch return mer.internalError("sources render failed");
    filterChip(req, w, "Assignment", "/sources?type=assignment", std.mem.eql(u8, filter_type, "assignment")) catch return mer.internalError("sources render failed");
    filterChip(req, w, "Announcement", "/sources?type=announcement", std.mem.eql(u8, filter_type, "announcement")) catch return mer.internalError("sources render failed");

    w.writeAll(
        \\  </fieldset>
        \\  <div class="cp-source-list cp-source-library">
    ) catch return mer.internalError("sources render failed");

    var shown: usize = 0;
    if (live_sources) |sources| {
        for (sources) |source| {
            if (filter_type.len > 0 and !std.mem.eql(u8, source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            shown += 1;
            renderBackendSource(req, w, source, now_secs) catch return mer.internalError("sources render failed");
        }
    } else {
        for (lib.mock.sources) |source| {
            if (filter_type.len > 0 and !std.mem.eql(u8, source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            shown += 1;
            renderMockSource(req, w, source, now_secs) catch return mer.internalError("sources render failed");
        }
    }

    if (shown == 0) {
        const empty_copy: []const u8 = if (filter_type.len > 0 or filter_status.len > 0) "No sources match this filter yet." else "No sources have been imported yet.";
        w.print("    <div class=\"cp-empty\">{s}</div>\n", .{empty_copy}) catch return mer.internalError("sources render failed");
    }

    w.writeAll(
        \\  </div>
        \\</section>
    ) catch return mer.internalError("sources render failed");

    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn metricCard(w: *std.Io.Writer, label: []const u8, value: usize, helper: []const u8) !void {
    try w.print(
        \\  <div class="cp-metric-card cp-metric-static">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">{d}</span>
        \\    <span class="cp-metric-sub">{s}</span>
        \\  </div>
    , .{ label, value, helper });
}

fn filterChip(req: mer.Request, w: *std.Io.Writer, label: []const u8, path: []const u8, active: bool) !void {
    const cls: []const u8 = if (active) "cp-chip cp-chip-active" else "cp-chip";
    const href = try lib.m3.demoHref(req.allocator, req, path);
    try w.print("    <a class=\"{s}\" href=\"{s}\">{s}</a>\n", .{ cls, href, label });
}

fn sourceStatusClass(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "ready") or std.mem.eql(u8, status, "indexed")) return "cp-source-status cp-source-status-indexed";
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "archived") or std.mem.eql(u8, status, "needs review")) return "cp-source-status cp-source-status-review";
    if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "indexing") or std.mem.eql(u8, status, "processing")) return "cp-source-status cp-source-status-processing";
    return "cp-source-status";
}

fn matchesStatus(actual: []const u8, selected: []const u8) bool {
    if (selected.len == 0) return true;
    if (std.mem.eql(u8, actual, selected)) return true;
    if (std.mem.eql(u8, selected, "ready")) return std.mem.eql(u8, actual, "indexed");
    if (std.mem.eql(u8, selected, "indexing")) return std.mem.eql(u8, actual, "processing");
    if (std.mem.eql(u8, selected, "pending")) return std.mem.eql(u8, actual, "processing");
    if (std.mem.eql(u8, selected, "failed")) return std.mem.eql(u8, actual, "needs review");
    return false;
}

fn renderBackendSource(
    req: mer.Request,
    w: *std.Io.Writer,
    source: lib.types.SourceResponse,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const summary = if (source.import_error) |err| err else source.citation_label;
    const safe_summary = lib.ui.escapeSafe(req.allocator, summary);
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const action_href_raw = if (source.source_url.len > 0) source.source_url else "/chat";
    const action_href = lib.m3.safeSourceHref(action_href_raw, "/sources");
    const safe_action_href = lib.ui.escape(req.allocator, action_href) catch "/sources";
    const action_copy: []const u8 = if (std.mem.startsWith(u8, action_href, "/")) "Ask with source" else "Open source";
    const status_cls = sourceStatusClass(source.status);

    try w.print(
        \\    <article class="cp-source-card">
        \\      <div class="cp-source-card-head">
        \\        <span class="cp-source-type">{s}</span>
        \\        <span class="{s}">{s}</span>
        \\      </div>
        \\      <div class="cp-source-title">{s}</div>
        \\      <p>{s}</p>
        \\      <div class="cp-topic-row">
    , .{ source.source_type, status_cls, source.status, safe_title, safe_summary });

    for (source.topic_tags) |topic| {
        const safe_topic = lib.ui.escapeSafe(req.allocator, topic);
        try w.print("        <span class=\"cp-topic-pill\">{s}</span>\n", .{safe_topic});
    }

    try w.print(
        \\      </div>
        \\      <div class="cp-source-footer">
        \\        <span>updated {s}</span>
        \\        <a href="{s}">{s}</a>
        \\      </div>
        \\    </article>
    , .{ when, safe_action_href, action_copy });
}

fn renderMockSource(
    req: mer.Request,
    w: *std.Io.Writer,
    source: lib.types.WorkspaceSource,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, source.summary);
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const action_href_raw = if (source.url.len > 0) source.url else "/chat";
    const action_href = lib.m3.safeSourceHref(action_href_raw, "/sources");
    const demo_href = if (std.mem.startsWith(u8, action_href, "/")) try lib.m3.demoHref(req.allocator, req, action_href) else action_href;
    const safe_action_href = lib.ui.escape(req.allocator, demo_href) catch "/sources?mock=1";
    const action_copy: []const u8 = if (std.mem.startsWith(u8, action_href, "/wiki/")) "Open wiki" else if (std.mem.startsWith(u8, action_href, "http")) "Open source" else "Open source";
    const status_cls = sourceStatusClass(source.status);

    try w.print(
        \\    <article class="cp-source-card">
        \\      <div class="cp-source-card-head">
        \\        <span class="cp-source-type">{s}</span>
        \\        <span class="{s}">{s}</span>
        \\      </div>
        \\      <div class="cp-source-title">{s}</div>
        \\      <p>{s}</p>
        \\      <div class="cp-topic-row">
    , .{ source.source_type, status_cls, source.status, safe_title, safe_summary });

    for (source.topics) |topic| {
        const safe_topic = lib.ui.escapeSafe(req.allocator, topic);
        try w.print("        <span class=\"cp-topic-pill\">{s}</span>\n", .{safe_topic});
    }

    try w.print(
        \\      </div>
        \\      <div class="cp-source-footer">
        \\        <span>{d} chunks · updated {s}</span>
        \\        <a href="{s}">{s}</a>
        \\      </div>
        \\    </article>
    , .{ source.chunk_count, when, safe_action_href, action_copy });
}
