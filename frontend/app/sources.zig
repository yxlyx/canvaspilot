// app/sources.zig — Milestone 2 source library prototype.
//
// Shows imported workspace sources that power Q&A, generated wiki pages, and
// flashcard decks. Authenticated sessions try backend metadata first and keep
// fixture data as a stable demo fallback.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sources",
    .description = "Review imported workspace sources and indexing state.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    const raw_filter_type = req.queryParam("type") orelse "";
    const raw_filter_status = req.queryParam("status") orelse "";
    const filter_type = lib.form.decode(req.allocator, raw_filter_type) catch raw_filter_type;
    const filter_status = lib.form.decode(req.allocator, raw_filter_status) catch raw_filter_status;
    const now_secs = lib.time.nowSecs();

    var live_sources: ?[]const lib.types.SourceResponse = null;
    var backend_message: ?[]const u8 = if (use_mock) "Showing prototype source fixtures." else null;
    if (!use_mock) {
        const result = lib.backend.listSources(req.allocator, session.token);
        if (result.value) |parsed_sources| {
            if (parsed_sources.value.len > 0) {
                live_sources = parsed_sources.value;
                backend_message = null;
            } else {
                backend_message = "No backend sources found yet — showing prototype fixtures.";
            }
        } else {
            backend_message = "Backend source metadata is unavailable — showing prototype fixtures.";
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

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <div class="cp-page-title">Source library</div>
        \\    <div class="cp-page-sub">Track what has been imported, chunked, and made available for cited answers.</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="/dashboard">Workspace</a>
        \\    <a class="cp-btn cp-btn-primary" href="/chat">Ask with sources</a>
        \\  </div>
        \\</header>
    ) catch return mer.internalError("sources render failed");

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("sources render failed");
    metricCard(w, "Ready", ready_count, "available for Q&A") catch return mer.internalError("sources render failed");
    metricCard(w, "Needs review", review_count, "failed or archived") catch return mer.internalError("sources render failed");
    metricCard(w, "Processing", processing_count, "pending import") catch return mer.internalError("sources render failed");
    metricCard(w, "Chunks", total_chunks, "fixture total") catch return mer.internalError("sources render failed");
    w.writeAll("</section>\n") catch return mer.internalError("sources render failed");

    if (backend_message) |message| {
        const safe_message = lib.ui.escape(req.allocator, message) catch message;
        w.print("<div class=\"cp-status-banner cp-status-info\">{s}</div>\n", .{safe_message}) catch return mer.internalError("sources render failed");
    } else if (filter_type.len > 0 or filter_status.len > 0) {
        w.writeAll("<div class=\"cp-status-banner cp-status-info\">Filtered source view. <a href=\"/sources\">Clear filters</a></div>\n") catch return mer.internalError("sources render failed");
    }

    w.writeAll(
        \\<section class="cp-card">
        \\  <div class="cp-card-title"><span>Import queue</span><span>metadata</span></div>
        \\  <div class="cp-filter-row" aria-label="Source filters">
    ) catch return mer.internalError("sources render failed");

    filterChip(w, "All", "/sources", filter_type.len == 0 and filter_status.len == 0) catch return mer.internalError("sources render failed");
    filterChip(w, "Ready", "/sources?status=ready", std.mem.eql(u8, filter_status, "ready")) catch return mer.internalError("sources render failed");
    filterChip(w, "Indexing", "/sources?status=indexing", std.mem.eql(u8, filter_status, "indexing")) catch return mer.internalError("sources render failed");
    filterChip(w, "Pending", "/sources?status=pending", std.mem.eql(u8, filter_status, "pending")) catch return mer.internalError("sources render failed");
    filterChip(w, "Review", "/sources?status=failed", std.mem.eql(u8, filter_status, "failed")) catch return mer.internalError("sources render failed");
    filterChip(w, "Markdown", "/sources?type=markdown", std.mem.eql(u8, filter_type, "markdown")) catch return mer.internalError("sources render failed");
    filterChip(w, "PDF", "/sources?type=pdf", std.mem.eql(u8, filter_type, "pdf")) catch return mer.internalError("sources render failed");

    w.writeAll(
        \\  </div>
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
        w.writeAll("    <div class=\"cp-empty\">No sources match this filter yet.</div>\n") catch return mer.internalError("sources render failed");
    }

    w.writeAll(
        \\  </div>
        \\</section>
    ) catch return mer.internalError("sources render failed");

    return lib.ui.htmlResponse(&buf);
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

fn filterChip(w: *std.Io.Writer, label: []const u8, href: []const u8, active: bool) !void {
    const cls: []const u8 = if (active) "cp-chip cp-chip-active" else "cp-chip";
    try w.print("    <a class=\"{s}\" href=\"{s}\">{s}</a>\n", .{ cls, href, label });
}

fn sourceStatusClass(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "ready") or std.mem.eql(u8, status, "indexed")) return "cp-source-status cp-source-status-indexed";
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "archived") or std.mem.eql(u8, status, "needs review")) return "cp-source-status cp-source-status-review";
    if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "indexing") or std.mem.eql(u8, status, "processing")) return "cp-source-status cp-source-status-processing";
    return "cp-source-status";
}

fn safeHref(raw: []const u8, fallback: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw, "https://")) return raw;
    if (std.mem.startsWith(u8, raw, "http://")) return raw;
    if (std.mem.startsWith(u8, raw, "/")) return raw;
    return fallback;
}

fn matchesStatus(actual: []const u8, selected: []const u8) bool {
    if (selected.len == 0) return true;
    if (std.mem.eql(u8, actual, selected)) return true;
    if (std.mem.eql(u8, selected, "ready")) return std.mem.eql(u8, actual, "indexed");
    if (std.mem.eql(u8, selected, "indexing")) return std.mem.eql(u8, actual, "processing");
    if (std.mem.eql(u8, selected, "failed")) return std.mem.eql(u8, actual, "needs review");
    return false;
}

fn renderBackendSource(
    req: mer.Request,
    w: *std.Io.Writer,
    source: lib.types.SourceResponse,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escape(req.allocator, source.title) catch source.title;
    const summary = if (source.import_error) |err| err else source.citation_label;
    const safe_summary = lib.ui.escape(req.allocator, summary) catch summary;
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const action_href_raw = if (source.source_url.len > 0) source.source_url else "/chat";
    const action_href = safeHref(action_href_raw, "/sources");
    const safe_action_href = lib.ui.escape(req.allocator, action_href) catch "/sources";
    const action_copy: []const u8 = if (std.mem.startsWith(u8, action_href, "http")) "Open source" else "Ask with source";
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
        const safe_topic = lib.ui.escape(req.allocator, topic) catch topic;
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
    const safe_title = lib.ui.escape(req.allocator, source.title) catch source.title;
    const safe_summary = lib.ui.escape(req.allocator, source.summary) catch source.summary;
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const action_href_raw = if (source.url.len > 0) source.url else "/chat";
    const action_href = safeHref(action_href_raw, "/sources");
    const safe_action_href = lib.ui.escape(req.allocator, action_href) catch "/sources";
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
        const safe_topic = lib.ui.escape(req.allocator, topic) catch topic;
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
