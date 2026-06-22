// app/sources.zig — Milestone 2 source library prototype.
//
// Shows the indexed Canvas/course sources that power workspace Q&A, generated
// wiki pages, and flashcard decks. Uses fixture metadata until source endpoints
// are available from the backend.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sources",
    .description = "Review imported workspace sources and indexing state.",
};

pub fn render(req: mer.Request) mer.Response {
    const raw_filter_type = req.queryParam("type") orelse "";
    const raw_filter_status = req.queryParam("status") orelse "";
    const filter_type = lib.form.decode(req.allocator, raw_filter_type) catch raw_filter_type;
    const filter_status = lib.form.decode(req.allocator, raw_filter_status) catch raw_filter_status;
    const now_secs = lib.time.nowSecs();

    var total_chunks: usize = 0;
    var indexed_count: usize = 0;
    var review_count: usize = 0;
    var processing_count: usize = 0;
    for (lib.mock.sources) |source| {
        total_chunks += source.chunk_count;
        if (std.mem.eql(u8, source.status, "indexed")) indexed_count += 1;
        if (std.mem.eql(u8, source.status, "needs review")) review_count += 1;
        if (std.mem.eql(u8, source.status, "processing")) processing_count += 1;
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
    metricCard(w, "Indexed", indexed_count, "ready for Q&A") catch return mer.internalError("sources render failed");
    metricCard(w, "Needs review", review_count, "citation quality") catch return mer.internalError("sources render failed");
    metricCard(w, "Processing", processing_count, "queued import") catch return mer.internalError("sources render failed");
    metricCard(w, "Chunks", total_chunks, "retrieval units") catch return mer.internalError("sources render failed");
    w.writeAll("</section>\n") catch return mer.internalError("sources render failed");

    if (filter_type.len > 0 or filter_status.len > 0) {
        w.writeAll("<div class=\"cp-status-banner cp-status-info\">Filtered source view. <a href=\"/sources\">Clear filters</a></div>\n") catch return mer.internalError("sources render failed");
    }

    w.writeAll(
        \\<section class="cp-card">
        \\  <div class="cp-card-title"><span>Import queue</span><span>prototype data</span></div>
        \\  <div class="cp-filter-row" aria-label="Source filters">
    ) catch return mer.internalError("sources render failed");

    filterChip(w, "All", "/sources", filter_type.len == 0 and filter_status.len == 0) catch return mer.internalError("sources render failed");
    filterChip(w, "Indexed", "/sources?status=indexed", std.mem.eql(u8, filter_status, "indexed")) catch return mer.internalError("sources render failed");
    filterChip(w, "Needs review", "/sources?status=needs%20review", std.mem.eql(u8, filter_status, "needs review")) catch return mer.internalError("sources render failed");
    filterChip(w, "Processing", "/sources?status=processing", std.mem.eql(u8, filter_status, "processing")) catch return mer.internalError("sources render failed");
    filterChip(w, "Assignments", "/sources?type=assignment", std.mem.eql(u8, filter_type, "assignment")) catch return mer.internalError("sources render failed");
    filterChip(w, "Markdown", "/sources?type=markdown", std.mem.eql(u8, filter_type, "markdown")) catch return mer.internalError("sources render failed");

    w.writeAll(
        \\  </div>
        \\  <div class="cp-source-list cp-source-library">
    ) catch return mer.internalError("sources render failed");

    var shown: usize = 0;
    for (lib.mock.sources) |source| {
        if (filter_type.len > 0 and !std.mem.eql(u8, source.source_type, filter_type)) continue;
        if (filter_status.len > 0 and !std.mem.eql(u8, source.status, filter_status)) continue;
        shown += 1;
        renderSource(req, w, source, now_secs) catch return mer.internalError("sources render failed");
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
    if (std.mem.eql(u8, status, "indexed")) return "cp-source-status cp-source-status-indexed";
    if (std.mem.eql(u8, status, "needs review")) return "cp-source-status cp-source-status-review";
    if (std.mem.eql(u8, status, "processing")) return "cp-source-status cp-source-status-processing";
    return "cp-source-status";
}

fn renderSource(
    req: mer.Request,
    w: *std.Io.Writer,
    source: lib.types.WorkspaceSource,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escape(req.allocator, source.title) catch source.title;
    const safe_summary = lib.ui.escape(req.allocator, source.summary) catch source.summary;
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const action_href = if (source.url.len > 0) source.url else "/chat";
    const action_copy: []const u8 = if (std.mem.startsWith(u8, action_href, "/wiki/")) "Open wiki" else if (std.mem.startsWith(u8, action_href, "http")) "Open Canvas" else "Open source";
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
    , .{ source.chunk_count, when, action_href, action_copy });
}
