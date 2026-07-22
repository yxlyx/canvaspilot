const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sources",
    .description = "Search, preview, filter, and import source documents.",
};

const ICON_SEARCH = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"11\" cy=\"11\" r=\"8\"/><path d=\"m21 21-4.3-4.3\"/></svg>";
const ICON_PLUS = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 5v14M5 12h14\"/></svg>";
const ICON_GRID = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"7\" height=\"7\" x=\"3\" y=\"3\"/><rect width=\"7\" height=\"7\" x=\"14\" y=\"3\"/><rect width=\"7\" height=\"7\" x=\"3\" y=\"14\"/><rect width=\"7\" height=\"7\" x=\"14\" y=\"14\"/></svg>";
const ICON_LIST = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01\"/></svg>";
const ICON_LIBRARY = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"8\" height=\"18\" x=\"3\" y=\"3\" rx=\"1\"/><path d=\"M7 3v18\"/><path d=\"M20.4 18.9c.2.5-.1 1.1-.6 1.3l-1.9.7c-.5.2-1.1-.1-1.3-.6L11.1 5.1c-.2-.5.1-1.1.6-1.3l1.9-.7c.5-.2 1.1.1 1.3.6Z\"/></svg>";
const ICON_CHECK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"m8 12 2.5 2.5L16 9\"/></svg>";
const ICON_DASHED = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\" stroke-dasharray=\"3 3\"/></svg>";
const ICON_ALERT = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 7v6M12 17h.01\"/></svg>";
const ICON_FILTER = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6\"/></svg>";
const ICON_MORE = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"5\" cy=\"12\" r=\"1\"/><circle cx=\"12\" cy=\"12\" r=\"1\"/><circle cx=\"19\" cy=\"12\" r=\"1\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M5 12h14M13 6l6 6-6 6\"/></svg>";
const ICON_INFO = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 11v5M12 8h.01\"/></svg>";

const Source = struct {
    id: []const u8,
    title: []const u8,
    module: []const u8,
    format: []const u8,
    detail: []const u8,
    status: []const u8,
    tags: []const u8,
    updated: []const u8,
};

const sources = [_]Source{
    .{ .id = "lecture-08", .title = "Lecture 08 — Balanced Search Trees", .module = "CS2040S", .format = "PDF", .detail = "42 pages", .status = "Ready", .tags = "AVL trees · Red-black trees", .updated = "Indexed 18 min ago" },
    .{ .id = "tutorial-05", .title = "Tutorial 05 — Graph Traversal", .module = "CS2040S", .format = "PDF", .detail = "8 pages", .status = "Ready", .tags = "BFS · DFS", .updated = "Indexed yesterday" },
    .{ .id = "team-guide", .title = "Project Team Guide", .module = "CS2103T", .format = "URL", .detail = "Web page", .status = "Importing", .tags = "Collaboration", .updated = "Parsing sections" },
    .{ .id = "ethics-reader", .title = "Digital Ethics Reader", .module = "IS1108", .format = "PDF", .detail = "96 pages", .status = "Needs attention", .tags = "Consent · Platforms", .updated = "2 pages could not be read" },
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
        if (result.value) |parsed| {
            live_sources = parsed.value;
        } else {
            return lib.m3.liveError(req, "Source library", result.status);
        }
    }

    var ready_count: usize = 0;
    var importing_count: usize = 0;
    var attention_count: usize = 0;
    var library_count: usize = 0;
    var total_chunks: usize = 0;
    if (live_sources) |items| {
        library_count = items.len;
        for (items) |source| {
            const display_status = sourceDisplayStatus(source.status);
            if (std.mem.eql(u8, display_status, "Ready")) ready_count += 1 else if (std.mem.eql(u8, display_status, "Importing")) importing_count += 1 else attention_count += 1;
        }
    } else {
        library_count = lib.mock.sources.len;
        for (lib.mock.sources) |source| {
            total_chunks += source.chunk_count;
            const display_status = sourceDisplayStatus(source.status);
            if (std.mem.eql(u8, display_status, "Ready")) ready_count += 1 else if (std.mem.eql(u8, display_status, "Importing")) importing_count += 1 else attention_count += 1;
        }
    }

    var shown: usize = 0;
    if (live_sources) |items| {
        for (items) |source| {
            if (filter_type.len > 0 and !std.mem.eql(u8, source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            shown += 1;
        }
    } else {
        for (lib.mock.sources) |source| {
            if (filter_type.len > 0 and !std.mem.eql(u8, source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            shown += 1;
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoBanner(req, w) catch return mer.internalError("sources render failed");
    w.print("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">{d} sources · ", .{library_count}) catch return mer.internalError("sources render failed");
    if (live_sources != null) {
        w.writeAll("chunks not reported") catch return mer.internalError("sources render failed");
    } else {
        w.print("{d} chunks", .{total_chunks}) catch return mer.internalError("sources render failed");
    }
    w.writeAll("</p><h1 class=\"cp-page-title\">Source library</h1></div></header><div class=\"sources-page\"><section class=\"docs-workspace\" aria-label=\"Source documents\"><header class=\"docs-toolbar\"><label class=\"docs-search\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("sources render failed");
    w.writeAll("<input id=\"cp-source-search\" placeholder=\"Search documents, modules, or topics\" aria-label=\"Search source documents\"></label><button class=\"docs-add-button\" id=\"cp-add-source\" type=\"button\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_PLUS) catch return mer.internalError("sources render failed");
    w.print("Add source</button></header><div class=\"docs-layout\"><section class=\"docs-main\" aria-labelledby=\"cp-source-heading\"><header class=\"docs-heading\"><div><p class=\"docs-kicker\">Workspace knowledge library</p><h2 id=\"cp-source-heading\">All documents</h2><span><b id=\"cp-source-count\">{d}</b> sources · previews show the indexed document</span></div><div class=\"docs-heading-actions\" aria-label=\"Document view options\"><button class=\"active\" type=\"button\" data-source-view=\"grid\" aria-label=\"Grid view\" aria-pressed=\"true\">", .{shown}) catch return mer.internalError("sources render failed");
    w.writeAll(ICON_GRID) catch return mer.internalError("sources render failed");
    w.writeAll("</button><button type=\"button\" data-source-view=\"list\" aria-label=\"List view\" aria-pressed=\"false\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_LIST) catch return mer.internalError("sources render failed");
    w.writeAll("</button></div></header><form class=\"source-filter-bar\" method=\"get\" action=\"/sources\" aria-label=\"Source filters\">") catch return mer.internalError("sources render failed");
    if (use_mock) w.writeAll("<input type=\"hidden\" name=\"mock\" value=\"1\">") catch return mer.internalError("sources render failed");
    w.writeAll("<div class=\"source-status-tabs\" role=\"group\" aria-label=\"Import status\">") catch return mer.internalError("sources render failed");
    tryFilterCount(w, "All", "", library_count, ICON_LIBRARY, filter_status.len == 0) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Ready", "ready", ready_count, ICON_CHECK, std.mem.eql(u8, filter_status, "ready")) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Importing", "indexing", importing_count, ICON_DASHED, std.mem.eql(u8, filter_status, "indexing")) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Needs attention", "failed", attention_count, ICON_ALERT, std.mem.eql(u8, filter_status, "failed")) catch return mer.internalError("sources render failed");
    w.writeAll("</div><div class=\"source-filter-selects\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_FILTER) catch return mer.internalError("sources render failed");
    w.print("<label><span class=\"sr-only\">Format</span><select id=\"cp-source-format\" name=\"type\" aria-label=\"Format\"><option value=\"\">All formats</option><option value=\"markdown\"{s}>Markdown</option><option value=\"assignment\"{s}>Assignments</option><option value=\"announcement\"{s}>Announcements</option></select></label><button class=\"button button-secondary button-small\" type=\"submit\">Apply</button></div></form><section class=\"document-grid grid\" id=\"cp-document-grid\" aria-live=\"polite\">", .{ if (std.mem.eql(u8, filter_type, "markdown")) " selected" else "", if (std.mem.eql(u8, filter_type, "assignment")) " selected" else "", if (std.mem.eql(u8, filter_type, "announcement")) " selected" else "" }) catch return mer.internalError("sources render failed");
    if (live_sources) |items| {
        for (items) |source| {
            if (filter_type.len > 0 and !std.mem.eql(u8, source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            renderLiveSource(req, w, source, now_secs) catch return mer.internalError("sources render failed");
        }
    } else {
        for (lib.mock.sources) |source| {
            if (filter_type.len > 0 and !std.mem.eql(u8, source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            renderMockSource(req, w, source, now_secs) catch return mer.internalError("sources render failed");
        }
    }
    if (shown == 0) {
        const empty_copy: []const u8 = if (filter_type.len > 0 or filter_status.len > 0) "No sources match these filters." else "No sources have been imported yet.";
        const clear_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("sources render failed");
        w.print("<div class=\"docs-empty\"><h3>{s}</h3><p>Try another status or format.</p><a class=\"button button-secondary\" href=\"{s}\">Clear filters</a></div>", .{ empty_copy, clear_href }) catch return mer.internalError("sources render failed");
    }
    w.writeAll("</section><div class=\"docs-empty\" id=\"cp-source-empty\" hidden>") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("sources render failed");
    w.writeAll("<h3>No documents match</h3><p>Try another title, topic, status, or format.</p><button id=\"cp-clear-source-filters\" type=\"button\">Clear filters</button></div><div class=\"docs-import-note\"><span>") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_INFO) catch return mer.internalError("sources render failed");
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("sources render failed");
    w.print("</span><p><strong>Every answer keeps its evidence close.</strong> Imported documents are parsed into topics while preserving links from wiki claims and answers back to the source.</p><a href=\"{s}\">Open generated wiki ", .{wiki_href}) catch return mer.internalError("sources render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("sources render failed");
    w.writeAll("</a></div></section></div></section></div>") catch return mer.internalError("sources render failed");
    renderDialogs(w) catch return mer.internalError("sources render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn tryFilter(w: *std.Io.Writer, label: []const u8, count: []const u8, icon: []const u8, active: bool) !void {
    try w.print("<button class=\"{s}\" type=\"button\" data-source-status=\"{s}\" aria-pressed=\"{s}\">{s}<span>{s}</span><b>{s}</b></button>", .{ if (active) "active" else "", label, if (active) "true" else "false", icon, label, count });
}

fn tryFilterCount(w: *std.Io.Writer, label: []const u8, value: []const u8, count: usize, icon: []const u8, active: bool) !void {
    try w.print("<button class=\"{s}\" type=\"submit\" name=\"status\" value=\"{s}\" data-source-status=\"{s}\" aria-pressed=\"{s}\">{s}<span>{s}</span><b>{d}</b></button>", .{ if (active) "active" else "", value, label, if (active) "true" else "false", icon, label, count });
}

fn matchesStatus(actual: []const u8, selected: []const u8) bool {
    if (selected.len == 0 or std.mem.eql(u8, actual, selected)) return true;
    if (std.mem.eql(u8, selected, "ready")) return std.mem.eql(u8, actual, "indexed");
    if (std.mem.eql(u8, selected, "indexing")) return std.mem.eql(u8, actual, "pending") or std.mem.eql(u8, actual, "processing");
    if (std.mem.eql(u8, selected, "failed")) return std.mem.eql(u8, actual, "archived") or std.mem.eql(u8, actual, "needs review");
    return false;
}

fn sourceDisplayStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "ready") or std.mem.eql(u8, status, "indexed")) return "Ready";
    if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "indexing") or std.mem.eql(u8, status, "processing")) return "Importing";
    return "Needs attention";
}

fn sourceDisplayFormat(source_type: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(source_type, "url") or std.ascii.eqlIgnoreCase(source_type, "web") or std.ascii.eqlIgnoreCase(source_type, "web_page")) return "URL";
    return "PDF";
}

fn renderLiveSource(req: mer.Request, w: *std.Io.Writer, source: lib.types.SourceResponse, now_secs: i64) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const safe_type = lib.ui.escapeSafe(req.allocator, source.source_type);
    const safe_origin = lib.ui.escapeSafe(req.allocator, source.origin);
    const safe_status = lib.ui.escapeSafe(req.allocator, source.status);
    const safe_label = lib.ui.escapeSafe(req.allocator, source.citation_label);
    const display_status = sourceDisplayStatus(source.status);
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const href = lib.m3.safeSourceHref(if (source.source_url.len > 0) source.source_url else "/chat", "/sources");
    const safe_href = lib.ui.escape(req.allocator, href) catch "/sources";
    const module_raw = source.course_context orelse source.project_context orelse "Workspace";
    const safe_module = lib.ui.escapeSafe(req.allocator, module_raw);
    const safe_course = lib.ui.escapeSafe(req.allocator, source.course_context orelse "None");
    const safe_project = lib.ui.escapeSafe(req.allocator, source.project_context orelse "None");
    const safe_user = lib.ui.escapeSafe(req.allocator, source.user_id);
    const error_raw = source.import_error orelse "No import errors";
    const safe_error = lib.ui.escapeSafe(req.allocator, error_raw);
    const imported_raw = source.last_imported_at orelse "Not imported yet";
    const safe_imported = lib.ui.escapeSafe(req.allocator, imported_raw);
    const external_raw = source.external_id orelse "None";
    const safe_external = lib.ui.escapeSafe(req.allocator, external_raw);
    try w.print("<article class=\"document-card\" data-title=\"{s}\" data-module=\"{s}\" data-format=\"{s}\" data-status=\"{s}\" data-tags=\"{s}\"><header><div><h3>{s}</h3><p>{s} · {s} · updated {s}</p></div><button class=\"document-menu\" type=\"button\" aria-label=\"More actions for {s}\">{s}</button></header><button class=\"document-preview-button\" data-source-preview type=\"button\" aria-label=\"Preview {s}\"><div class=\"document-paper\"><div class=\"paper-running-head\"><span>{s}</span><span>{s}</span></div><span class=\"paper-kicker\">{s}</span><h3>{s}</h3><p class=\"paper-lede\">{s}</p><div class=\"paper-rule\"></div><p><strong>Import:</strong> {s}</p><p><strong>Error:</strong> {s}</p><span class=\"paper-page\">chunks not reported</span></div></button><footer><div><span class=\"status-pill status-{s}\">{s}</span><span class=\"document-tags\">", .{ safe_title, safe_module, safe_type, display_status, safe_label, safe_title, safe_module, safe_type, when, safe_title, ICON_MORE, safe_title, safe_module, safe_status, safe_origin, safe_title, safe_label, safe_imported, safe_error, if (std.mem.eql(u8, display_status, "Ready")) "good" else if (std.mem.eql(u8, display_status, "Importing")) "info" else "warn", display_status });
    for (source.topic_tags) |topic| try w.print("<span>{s}</span> ", .{lib.ui.escapeSafe(req.allocator, topic)});
    try w.print("</span></div><div class=\"document-metadata\"><small>ID {s} · owner {s} · external {s} · course {s} · project {s} · created {s} · updated {s}</small><a href=\"{s}\">{s} {s}</a></div></footer></article>", .{ lib.ui.escapeSafe(req.allocator, source.id), safe_user, safe_external, safe_course, safe_project, lib.ui.escapeSafe(req.allocator, source.created_at), lib.ui.escapeSafe(req.allocator, source.updated_at), safe_href, if (std.mem.startsWith(u8, href, "/")) "Ask with source" else "Open source", ICON_ARROW });
}

fn renderMockSource(req: mer.Request, w: *std.Io.Writer, source: lib.types.WorkspaceSource, now_secs: i64) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const safe_type = lib.ui.escapeSafe(req.allocator, source.source_type);
    const safe_module = lib.ui.escapeSafe(req.allocator, source.module_id);
    const safe_summary = lib.ui.escapeSafe(req.allocator, source.summary);
    const display_status = sourceDisplayStatus(source.status);
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const raw_href = lib.m3.safeSourceHref(if (source.url.len > 0) source.url else "/chat", "/sources");
    const href = if (std.mem.startsWith(u8, raw_href, "/")) try lib.m3.demoHref(req.allocator, req, raw_href) else raw_href;
    const safe_href = lib.ui.escape(req.allocator, href) catch "/sources?mock=1";
    try w.print("<article class=\"document-card\" data-title=\"{s}\" data-module=\"{s}\" data-format=\"{s}\" data-status=\"{s}\" data-tags=\"{s}\"><header><div><h3>{s}</h3><p>{s} · {s} · {d} chunks · updated {s}</p></div><button class=\"document-menu\" type=\"button\" aria-label=\"More actions for {s}\">{s}</button></header><button class=\"document-preview-button\" data-source-preview type=\"button\" aria-label=\"Preview {s}\"><div class=\"document-paper\"><div class=\"paper-running-head\"><span>{s}</span><span>{s}</span></div><span class=\"paper-kicker\">SYNTHETIC DEMO SOURCE</span><h3>{s}</h3><p class=\"paper-lede\">{s}</p><div class=\"paper-rule\"></div><div class=\"scan-lines\"><i></i><i></i><i></i><i></i></div><span class=\"paper-page\">{d} chunks</span></div></button><footer><div><span class=\"status-pill status-{s}\">{s}</span><span class=\"document-tags\">", .{ safe_title, safe_module, safe_type, display_status, safe_summary, safe_title, safe_module, safe_type, source.chunk_count, when, safe_title, ICON_MORE, safe_title, safe_module, source.status, safe_title, safe_summary, source.chunk_count, if (std.mem.eql(u8, display_status, "Ready")) "good" else if (std.mem.eql(u8, display_status, "Importing")) "info" else "warn", display_status });
    for (source.topics) |topic| try w.print("<span>{s}</span> ", .{lib.ui.escapeSafe(req.allocator, topic)});
    try w.print("</span></div><div><button data-source-preview type=\"button\">Preview</button><a href=\"{s}\">Open source {s}</a></div></footer></article>", .{ safe_href, ICON_ARROW });
}

fn renderSource(req: mer.Request, w: *std.Io.Writer, source: Source) !void {
    const safe_title = lib.ui.escape(req.allocator, source.title) catch source.title;
    try w.print("<article class=\"document-card\" data-title=\"{s}\" data-module=\"{s}\" data-format=\"{s}\" data-status=\"{s}\" data-tags=\"{s}\"><header><div><h3>{s}</h3><p>{s} · {s} · {s} · {s}</p></div><button class=\"document-menu\" type=\"button\" aria-label=\"More actions for {s}\">{s}</button></header><button class=\"document-preview-button\" data-source-preview type=\"button\" aria-label=\"Preview {s}\">", .{ safe_title, source.module, source.format, source.status, source.tags, safe_title, source.module, source.format, source.detail, source.updated, safe_title, ICON_MORE, safe_title });
    try renderPaper(w, source.id);
    try w.print("</button><footer><div><span class=\"status-pill status-{s}\">{s}</span><span class=\"document-tags\">{s}</span></div><div><button data-source-preview type=\"button\">Preview</button><a href=\"/wiki\">Wiki {s}</a></div></footer></article>", .{ if (std.mem.eql(u8, source.status, "Ready")) "good" else if (std.mem.eql(u8, source.status, "Importing")) "info" else "warn", source.status, source.tags, ICON_ARROW });
}

fn renderPaper(w: *std.Io.Writer, id: []const u8) !void {
    if (std.mem.eql(u8, id, "lecture-08")) {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>CS2040S</span><span>COURSE NOTES</span></div><h3>Balanced Search Trees</h3><p class=\"paper-lede\">Maintaining logarithmic search through local structural invariants.</p><div class=\"paper-rule\"></div><h4>8.2 The AVL invariant</h4><p>For each node, the height of the left and right subtrees differs by at most one.</p><div class=\"mini-tree\"><i class=\"tree-edge edge-left\"></i><i class=\"tree-edge edge-right\"></i><b class=\"tree-point root-point\">8</b><b class=\"tree-point left-point\">4</b><b class=\"tree-point right-point\">12</b></div><div class=\"paper-note\"><strong>Key idea</strong><span>Rotations restore balance without changing the in-order sequence.</span></div><span class=\"paper-page\">01</span></div>");
    } else if (std.mem.eql(u8, id, "tutorial-05")) {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>CS2040S</span><span>COURSE NOTES</span></div><h3>Graph Traversal</h3><p class=\"paper-lede\">Tutorial 05 · Breadth-first and depth-first search</p><div class=\"paper-rule\"></div><h4>Problem 1 — Reachability</h4><p>Trace the frontier after each step, beginning at vertex A.</p><div class=\"graph-path\"><b>A</b><i></i><b>B</b><i></i><b>D</b><i></i><b>F</b></div><ol class=\"paper-steps\"><li>Mark the starting vertex.</li><li>Visit every unmarked neighbour.</li><li>Record the predecessor edge.</li></ol><span class=\"paper-page\">01</span></div>");
    } else if (std.mem.eql(u8, id, "team-guide")) {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>CS2103T</span><span>REFERENCE</span></div><span class=\"paper-kicker\">PROJECT HANDBOOK</span><h3>Architecture &amp;<br>Team Guide</h3><p class=\"paper-lede\">Working agreements for a maintainable software project.</p><div class=\"paper-rule\"></div><div class=\"guide-columns\"><div><strong>Decide</strong><span>Record context and trade-offs.</span></div><div><strong>Review</strong><span>Keep changes small and legible.</span></div></div><h4>Definition of done</h4><div class=\"check-line\">✓ Tests explain the behaviour</div><div class=\"check-line\">✓ Documentation stays current</div><span class=\"paper-page\">01</span></div>");
    } else {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>IS1108</span><span>COURSE NOTES</span></div><span class=\"paper-kicker\">IS1108 READER</span><h3>Meaningful Consent</h3><p class=\"paper-lede\">Agency, information asymmetry, and platform power.</p><div class=\"paper-rule\"></div><blockquote>Consent is meaningful only when refusal is understandable, accessible, and free from penalty.</blockquote><h4>Questions for analysis</h4><ul class=\"paper-list\"><li>Is the choice informed?</li><li>Can it be reversed?</li><li>Who benefits from the default?</li></ul><span class=\"paper-page\">01</span></div>");
    }
}

fn renderDialogs(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<div class="modal-backdrop document-preview-backdrop" id="cp-source-preview-modal" hidden><section class="document-preview-modal" role="dialog" aria-modal="true" aria-labelledby="cp-preview-title"><button class="preview-close" type="button" data-close-source-modal aria-label="Close document preview">×</button><div class="preview-document-stage"><div class="document-paper expanded"><span class="paper-kicker">SOURCE PREVIEW</span><h3 id="cp-preview-paper-title">Balanced Search Trees</h3><p class="paper-lede">Indexed evidence with preserved structure and citation anchors.</p><div class="paper-rule"></div><div class="scan-lines"><i></i><i></i><i></i><i></i></div></div></div><aside><p class="eyebrow">Source preview</p><h2 id="cp-preview-title">Source</h2><p id="cp-preview-detail">Course material</p><span class="status-pill status-good" id="cp-preview-status">Ready</span><dl><div><dt>Evidence</dt><dd>4 linked wiki claims</dd></div><div><dt>Traceability</dt><dd>Preserved</dd></div></dl><a class="button button-dark" href="/wiki">Open connected wiki →</a></aside></section></div>
        \\<div class="modal-backdrop" id="cp-add-source-modal" hidden><section class="source-modal surface" role="dialog" aria-modal="true" aria-labelledby="cp-add-source-title"><button class="modal-close" type="button" data-close-source-modal aria-label="Close add source dialog">×</button><p class="eyebrow">Add evidence</p><h2 id="cp-add-source-title">Bring in a course source.</h2><p>Add a public course resource and begin parsing it into traceable evidence.</p><form id="cp-add-source-form"><div class="field"><label for="cp-new-source-title">Source title</label><input id="cp-new-source-title" name="title" placeholder="e.g. Lecture 09 — Hash Tables" required></div><div class="field"><label for="cp-new-source-url">Public link</label><input id="cp-new-source-url" name="url" type="url" placeholder="https://..." required></div><div class="field"><label for="cp-new-source-module">Module</label><select id="cp-new-source-module" name="module"><option>CS2040S Data Structures</option><option>CS2103T Software Engineering</option><option>IS1108 Digital Ethics</option></select></div><button class="button button-dark" type="submit">Add and begin parsing</button></form></section></div>
    );
}
