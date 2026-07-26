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
    const raw_enrollment_id = req.queryParam("enrollment_id") orelse req.queryParam("module_scope") orelse "";
    const enrollment_id = lib.form.decode(req.allocator, raw_enrollment_id) catch raw_enrollment_id;
    const raw_topic_id = req.queryParam("topic_id") orelse "";
    const topic_id = lib.form.decode(req.allocator, raw_topic_id) catch raw_topic_id;
    const raw_source_id = req.queryParam("source") orelse "";
    const source_id = lib.form.decode(req.allocator, raw_source_id) catch raw_source_id;
    const now_secs = lib.time.nowSecs();

    if ((enrollment_id.len > 0 and !safeUuid(enrollment_id)) or (topic_id.len > 0 and !safeUuid(topic_id)) or (topic_id.len > 0 and enrollment_id.len == 0)) return mer.badRequest("invalid source guidance context");
    if (source_id.len > 0 and !safeUuid(source_id)) return mer.badRequest("invalid source identifier");
    var selected_enrollment: ?lib.types.EnrollmentResponse = null;
    var selected_topic_title: ?[]const u8 = null;
    if (!use_mock and enrollment_id.len > 0) {
        const result = lib.backend.listEnrollments(req.allocator, session.token);
        const enrollments = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Module scope", result.status);
        for (enrollments) |enrollment| {
            if (std.mem.eql(u8, enrollment.id, enrollment_id) and !enrollment.archived) {
                selected_enrollment = enrollment;
                break;
            }
        }
        if (selected_enrollment == null) return mer.badRequest("active module scope not found");
        if (topic_id.len > 0) {
            const topic_result = lib.backend.listEnrollmentTopics(req.allocator, session.token, enrollment_id);
            const topics = if (topic_result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Topic context", topic_result.status);
            for (topics) |topic| if (std.mem.eql(u8, topic.id, topic_id) and !topic.archived) {
                selected_topic_title = topic.title;
                break;
            };
            if (selected_topic_title == null) return mer.badRequest("topic does not belong to the selected enrollment");
        }
    } else if (use_mock and topic_id.len > 0) {
        selected_topic_title = "Synthetic topic fixture";
    }

    var live_sources: ?[]const lib.types.SourceResponse = null;
    var processing_runs: []const lib.types.ProcessingRunResponse = &.{};
    var processing_loaded = use_mock;
    const selected_run = req.queryParam("run") orelse "";
    if (selected_run.len > 0 and !safeUuid(selected_run)) return mer.badRequest("invalid processing run context");
    if (!use_mock) {
        const result = lib.backend.listSources(req.allocator, session.token);
        if (result.value) |parsed| {
            live_sources = parsed.value;
            if (source_id.len > 0) {
                var owns_source = false;
                for (parsed.value) |item| if (std.mem.eql(u8, item.id, source_id)) {
                    owns_source = true;
                    break;
                };
                if (!owns_source) return lib.m3.liveError(req, "Source record", 404);
            }
        } else {
            return lib.m3.liveError(req, "Source library", result.status);
        }
        const run_result = lib.backend.latestProcessingRuns(req.allocator, session.token);
        if (run_result.value) |parsed| {
            processing_runs = parsed.value;
            processing_loaded = true;
            if (selected_run.len > 0) {
                var selected_present = false;
                for (processing_runs) |run| if (std.mem.eql(u8, run.id, selected_run)) {
                    selected_present = true;
                    break;
                };
                if (!selected_present) {
                    const selected_result = lib.backend.processingRun(req.allocator, session.token, selected_run);
                    const selected = if (selected_result.value) |item| item.value else return lib.m3.liveError(req, "Processing run", selected_result.status);
                    const merged = req.allocator.alloc(lib.types.ProcessingRunResponse, processing_runs.len + 1) catch return mer.internalError("sources render failed");
                    @memcpy(merged[0..processing_runs.len], processing_runs);
                    merged[processing_runs.len] = selected;
                    processing_runs = merged;
                }
            }
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
            if (std.mem.eql(u8, display_status, "Ready")) ready_count += 1 else if (isActiveImportStatus(source.status)) importing_count += 1 else attention_count += 1;
        }
    } else {
        library_count = lib.mock.sources.len;
        for (lib.mock.sources) |source| {
            total_chunks += source.chunk_count;
            const display_status = sourceDisplayStatus(source.status);
            if (std.mem.eql(u8, display_status, "Ready")) ready_count += 1 else if (isActiveImportStatus(source.status)) importing_count += 1 else attention_count += 1;
        }
    }

    var shown: usize = 0;
    if (live_sources) |items| {
        for (items) |source| {
            if (!matchesType(source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            shown += 1;
        }
    } else {
        for (lib.mock.sources) |source| {
            if (!matchesType(source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            shown += 1;
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("sources render failed");
    w.print("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">{s}{d} sources", .{ if (use_mock) "Synthetic demo · " else "", library_count }) catch return mer.internalError("sources render failed");
    if (live_sources == null) w.print(" · {d} chunks", .{total_chunks}) catch return mer.internalError("sources render failed");
    w.writeAll("</p><h1 class=\"cp-page-title\">Source library</h1></div></header>") catch return mer.internalError("sources render failed");
    if (selected_enrollment) |enrollment| w.print("<div class=\"notice notice-info cp-source-scope\" role=\"status\"><strong>Module scope: {s} — {s}</strong><span>New sources added here will retain local enrollment <code>{s}</code>.</span></div>", .{ lib.ui.escapeSafe(req.allocator, enrollment.code), lib.ui.escapeSafe(req.allocator, enrollment.title), lib.ui.escapeSafe(req.allocator, enrollment.id) }) catch return mer.internalError("sources render failed");
    if (selected_topic_title) |title| w.print("<div class=\"notice notice-info cp-source-scope\" role=\"note\"><strong>Source needed for topic: {s}</strong><span>Import a source, then return to the dashboard to review an association. Importing never claims coverage automatically.</span></div>", .{lib.ui.escapeSafe(req.allocator, title)}) catch return mer.internalError("sources render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.source_tabs, "library", "Sources", use_mock) catch return mer.internalError("sources tabs failed");
    if (!use_mock) if (req.queryParam("import")) |state| {
        if (std.mem.eql(u8, state, "saved"))
            w.writeAll("<p class=\"docs-import-note\" role=\"status\">Bookmark metadata saved. Links are not processed or indexed.</p>") catch return mer.internalError("sources render failed")
        else if (std.mem.eql(u8, state, "completed"))
            w.writeAll("<p class=\"docs-import-note\" role=\"status\">Processing completed. The source is indexed; optional downstream stages are shown below.</p>") catch return mer.internalError("sources render failed")
        else if (std.mem.eql(u8, state, "paused"))
            w.writeAll("<p class=\"docs-import-note\" role=\"status\">Source saved, but processing is paused. Review the guidance below.</p>") catch return mer.internalError("sources render failed")
        else if (std.mem.eql(u8, state, "failed"))
            w.writeAll("<p class=\"docs-import-note\" role=\"alert\" tabindex=\"-1\">Processing failed. Any prior valid source, Wiki, or deck remains available.</p>") catch return mer.internalError("sources render failed")
        else
            w.print("<p class=\"docs-import-note\" role=\"status\">Source accepted. Persisted state: <strong>{s}</strong>. It is not indexed until processing completes.</p>", .{lib.ui.escapeSafe(req.allocator, state)}) catch return mer.internalError("sources render failed");
    };
    w.writeAll("<div class=\"sources-page\"><section class=\"docs-workspace\" aria-label=\"Source documents\"><header class=\"docs-toolbar\"><label class=\"docs-search\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("sources render failed");
    w.writeAll("<input id=\"cp-source-search\" placeholder=\"Search documents, modules, or topics\" aria-label=\"Search source documents\"></label><button class=\"docs-add-button\" id=\"cp-add-source\" type=\"button\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_PLUS) catch return mer.internalError("sources render failed");
    w.print("Add source</button></header><div class=\"docs-layout\"><section class=\"docs-main\" aria-labelledby=\"cp-source-heading\"><header class=\"docs-heading\"><div><p class=\"docs-kicker\">Workspace knowledge library</p><h2 id=\"cp-source-heading\">All documents</h2><span><b id=\"cp-source-count\">{d}</b> sources · {s}</span></div><div class=\"docs-heading-actions\" aria-label=\"Document view options\"><button class=\"active\" type=\"button\" data-source-view=\"grid\" aria-label=\"Grid view\" aria-pressed=\"true\">", .{ shown, if (use_mock) "previews show the indexed document" else "previews show stored source metadata" }) catch return mer.internalError("sources render failed");
    w.writeAll(ICON_GRID) catch return mer.internalError("sources render failed");
    w.writeAll("</button><button type=\"button\" data-source-view=\"list\" aria-label=\"List view\" aria-pressed=\"false\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_LIST) catch return mer.internalError("sources render failed");
    w.writeAll("</button></div></header><form class=\"source-filter-bar\" method=\"get\" action=\"/sources\" aria-label=\"Source filters\">") catch return mer.internalError("sources render failed");
    if (selected_enrollment) |enrollment| w.print("<input type=\"hidden\" name=\"enrollment_id\" value=\"{s}\">", .{lib.ui.escapeSafe(req.allocator, enrollment.id)}) catch return mer.internalError("sources render failed");
    if (topic_id.len > 0) w.print("<input type=\"hidden\" name=\"topic_id\" value=\"{s}\">", .{lib.ui.escapeSafe(req.allocator, topic_id)}) catch return mer.internalError("sources render failed");
    if (source_id.len > 0) w.print("<input type=\"hidden\" name=\"source\" value=\"{s}\">", .{lib.ui.escapeSafe(req.allocator, source_id)}) catch return mer.internalError("sources render failed");
    if (use_mock) w.writeAll("<input type=\"hidden\" name=\"mock\" value=\"1\">") catch return mer.internalError("sources render failed");
    w.writeAll("<div class=\"source-status-tabs\" role=\"group\" aria-label=\"Import status\">") catch return mer.internalError("sources render failed");
    tryFilterCount(w, "All", "", library_count, ICON_LIBRARY, filter_status.len == 0) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Ready", "ready", ready_count, ICON_CHECK, std.mem.eql(u8, filter_status, "ready")) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Pending / importing", "indexing", importing_count, ICON_DASHED, std.mem.eql(u8, filter_status, "indexing")) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Needs attention", "failed", attention_count, ICON_ALERT, std.mem.eql(u8, filter_status, "failed")) catch return mer.internalError("sources render failed");
    w.writeAll("</div><div class=\"source-filter-selects\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_FILTER) catch return mer.internalError("sources render failed");
    w.print("<label><span class=\"sr-only\">Format</span><select id=\"cp-source-format\" name=\"type\" aria-label=\"Format\"><option value=\"\">All formats</option><option value=\"document\"{s}>PDF and documents</option><option value=\"url\"{s}>Web pages</option></select></label>", .{ if (std.mem.eql(u8, filter_type, "document")) " selected" else "", if (std.mem.eql(u8, filter_type, "url")) " selected" else "" }) catch return mer.internalError("sources render failed");
    if (use_mock) w.writeAll("<label><span class=\"sr-only\">Module</span><select id=\"cp-source-module\" aria-label=\"Module\"><option>All</option><option>CS2030S</option></select></label>") catch return mer.internalError("sources render failed");
    w.writeAll("<button class=\"source-filter-submit\" type=\"submit\">Apply filters</button></div></form><section class=\"document-grid grid\" id=\"cp-document-grid\" aria-live=\"polite\">") catch return mer.internalError("sources render failed");
    if (live_sources) |items| {
        for (items) |source| {
            if (!matchesType(source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            renderLiveSource(req, w, source, latestRunForSource(processing_runs, source.id), now_secs, std.mem.eql(u8, source.id, source_id)) catch return mer.internalError("sources render failed");
        }
    } else {
        for (lib.mock.sources) |source| {
            if (!matchesType(source.source_type, filter_type)) continue;
            if (!matchesStatus(source.status, filter_status)) continue;
            renderMockSource(req, w, source, now_secs) catch return mer.internalError("sources render failed");
        }
    }
    if (shown == 0) {
        const empty_copy: []const u8 = if (filter_type.len > 0 or filter_status.len > 0) "No sources match these filters." else "No sources have been imported yet.";
        const clear_target = if (selected_enrollment) |enrollment| if (topic_id.len > 0) std.fmt.allocPrint(req.allocator, "/sources?enrollment_id={s}&topic_id={s}", .{ enrollment.id, topic_id }) catch "/sources" else std.fmt.allocPrint(req.allocator, "/sources?enrollment_id={s}", .{enrollment.id}) catch "/sources" else "/sources";
        const clear_href = lib.m3.demoHref(req.allocator, req, clear_target) catch return mer.internalError("sources render failed");
        w.print("<div class=\"docs-empty\"><h3>{s}</h3><p>Try another status or format.</p><a class=\"button button-secondary\" href=\"{s}\">Clear filters</a></div>", .{ empty_copy, clear_href }) catch return mer.internalError("sources render failed");
    }
    w.writeAll("</section><div class=\"docs-empty\" id=\"cp-source-empty\" hidden>") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("sources render failed");
    w.writeAll("<h3>No documents match</h3><p>Try another title, topic, status, or format.</p><button id=\"cp-clear-source-filters\" type=\"button\">Clear filters</button></div><div class=\"docs-import-note\"><span>") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_INFO) catch return mer.internalError("sources render failed");
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("sources render failed");
    w.print("</span><p><strong>Every answer keeps its evidence close.</strong> Imported documents are parsed into topics while preserving links from wiki claims and answers back to the source.</p><a href=\"{s}\">Open generated wiki ", .{wiki_href}) catch return mer.internalError("sources render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("sources render failed");
    w.writeAll("</a></div></section></div></section>") catch return mer.internalError("sources render failed");
    if (!processing_loaded and !use_mock) w.writeAll("<section class=\"cp-processing-panel surface\" id=\"processing\" aria-labelledby=\"processing-title\"><h2 id=\"processing-title\">Durable processing</h2><p class=\"cp-inline-error\" role=\"alert\">Run status is temporarily unavailable. Source records above are preserved; reload to try again.</p></section>") catch return mer.internalError("sources render failed") else lib.processing_ui.render(req.allocator, w, processing_runs, selected_run, use_mock) catch return mer.internalError("sources render failed");
    w.writeAll("</div>") catch return mer.internalError("sources render failed");
    renderDialogs(w, use_mock) catch return mer.internalError("sources render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn tryFilter(w: *std.Io.Writer, label: []const u8, count: []const u8, icon: []const u8, active: bool) !void {
    try w.print("<button class=\"{s}\" type=\"button\" data-source-status=\"{s}\" aria-pressed=\"{s}\">{s}<span>{s}</span><b>{s}</b></button>", .{ if (active) "active" else "", label, if (active) "true" else "false", icon, label, count });
}

fn tryFilterCount(w: *std.Io.Writer, label: []const u8, value: []const u8, count: usize, icon: []const u8, active: bool) !void {
    try w.print("<button class=\"{s}\" type=\"submit\" name=\"status\" value=\"{s}\" data-source-status=\"{s}\" aria-pressed=\"{s}\">{s}<span>{s}</span><b>{d}</b></button>", .{ if (active) "active" else "", value, label, if (active) "true" else "false", icon, label, count });
}

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

fn matchesStatus(actual: []const u8, selected: []const u8) bool {
    if (selected.len == 0 or std.mem.eql(u8, actual, selected)) return true;
    if (std.mem.eql(u8, selected, "ready")) return std.mem.eql(u8, actual, "indexed");
    if (std.mem.eql(u8, selected, "indexing")) return std.mem.eql(u8, actual, "pending") or std.mem.eql(u8, actual, "processing");
    if (std.mem.eql(u8, selected, "failed")) return std.mem.eql(u8, actual, "archived") or std.mem.eql(u8, actual, "needs review");
    return false;
}

fn matchesType(actual: []const u8, selected: []const u8) bool {
    if (selected.len == 0) return true;
    const is_web = std.ascii.eqlIgnoreCase(actual, "url") or std.ascii.eqlIgnoreCase(actual, "web") or std.ascii.eqlIgnoreCase(actual, "web_page") or std.ascii.eqlIgnoreCase(actual, "link");
    if (std.mem.eql(u8, selected, "url")) return is_web;
    if (std.mem.eql(u8, selected, "document")) return !is_web;
    return std.mem.eql(u8, actual, selected);
}

fn sourceDisplayStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "ready") or std.mem.eql(u8, status, "indexed")) return "Ready";
    if (std.mem.eql(u8, status, "pending")) return "Pending";
    if (std.mem.eql(u8, status, "indexing") or std.mem.eql(u8, status, "processing")) return "Importing";
    return "Needs attention";
}

fn isActiveImportStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "indexing") or std.mem.eql(u8, status, "processing") or std.mem.eql(u8, status, "Importing");
}

fn sourceDisplayFormat(source_type: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(source_type, "url") or std.ascii.eqlIgnoreCase(source_type, "web") or std.ascii.eqlIgnoreCase(source_type, "web_page") or std.ascii.eqlIgnoreCase(source_type, "link")) return "URL";
    if (std.ascii.eqlIgnoreCase(source_type, "pdf")) return "PDF";
    if (std.ascii.eqlIgnoreCase(source_type, "image")) return "Image";
    if (std.ascii.eqlIgnoreCase(source_type, "markdown")) return "Markdown";
    if (std.ascii.eqlIgnoreCase(source_type, "plain_text")) return "Text";
    if (std.ascii.eqlIgnoreCase(source_type, "repository")) return "Repository";
    return "Source";
}

fn latestRunForSource(runs: []const lib.types.ProcessingRunResponse, source_id: []const u8) ?lib.types.ProcessingRunResponse {
    for (runs) |run| if (std.mem.eql(u8, run.source_id, source_id)) return run;
    return null;
}

fn renderLiveSource(req: mer.Request, w: *std.Io.Writer, source: lib.types.SourceResponse, run: ?lib.types.ProcessingRunResponse, now_secs: i64, focused: bool) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const display_format = sourceDisplayFormat(source.source_type);
    const safe_status = lib.ui.escapeSafe(req.allocator, source.status);
    const safe_label = lib.ui.escapeSafe(req.allocator, source.citation_label);
    const display_status = if (std.ascii.eqlIgnoreCase(source.source_type, "link")) "Bookmark saved" else sourceDisplayStatus(source.status);
    const when = lib.time.formatRelative(req.allocator, source.updated_at, now_secs) catch "—";
    const href = lib.m3.safeSourceHref(if (source.source_url.len > 0) source.source_url else "/chat", "/sources");
    const safe_href = lib.ui.escape(req.allocator, href) catch "/sources";
    const module_raw = source.course_context orelse source.project_context orelse "Workspace";
    const safe_module = lib.ui.escapeSafe(req.allocator, module_raw);
    const error_raw = publicImportError(source.import_error orelse "No import errors");
    const safe_error = lib.ui.escapeSafe(req.allocator, error_raw);
    const imported_raw = source.last_imported_at orelse "Not imported yet";
    const safe_imported = lib.ui.escapeSafe(req.allocator, imported_raw);
    const processing_stage = if (run) |item| lib.processing_ui.stageLabel(item.current_stage) else if (std.ascii.eqlIgnoreCase(source.source_type, "link")) "No indexing required" else if (std.ascii.eqlIgnoreCase(source.status, "ready")) "Completed processing" else if (std.ascii.eqlIgnoreCase(source.status, "failed")) "Processing needs attention" else "Waiting for processing run";
    const safe_processing_stage = lib.ui.escapeSafe(req.allocator, processing_stage);
    const processing_when = if (run) |item| lib.time.formatRelative(req.allocator, item.updated_at, now_secs) catch "—" else when;
    const processing_status = if (run) |item| item.status else source.status;
    const latest_run_id = if (run) |item| item.id else "";
    try w.print("<article id=\"source-{s}\" class=\"document-card{s}\" data-source-id=\"{s}\" data-latest-run-id=\"{s}\" tabindex=\"-1\" data-title=\"{s}\" data-module=\"{s}\" data-format=\"{s}\" data-status=\"{s}\" data-display-status=\"{s}\" data-tags=\"{s}\"><header><div><h3>{s}</h3><p>{s} · {s} · updated {s}</p></div><button class=\"document-menu\" type=\"button\" aria-label=\"More actions for {s}\">{s}</button></header><button class=\"document-preview-button\" data-source-preview type=\"button\" aria-label=\"Preview {s}\"><div class=\"document-paper\"><div class=\"paper-running-head\"><span>{s}</span><span>{s}</span></div><span class=\"paper-kicker\">SOURCE PREVIEW</span><h3>{s}</h3><p class=\"paper-lede\">{s}</p><div class=\"paper-rule\"></div><p><strong>Import:</strong> {s}</p><p><strong>Status:</strong> {s}</p><p data-source-processing><strong>Processing:</strong> <span data-source-stage>{s}</span> · <span data-source-run-status>{s}</span> · updated <span data-source-run-updated>{s}</span></p><span class=\"paper-page\">Updated {s}</span></div></button><footer><div><span class=\"status-pill status-{s}\">{s}</span><span class=\"document-tags\">", .{ lib.ui.escapeSafe(req.allocator, source.id), if (focused) " is-focused" else "", lib.ui.escapeSafe(req.allocator, source.id), lib.ui.escapeSafe(req.allocator, latest_run_id), safe_title, safe_module, display_format, safe_status, display_status, safe_label, safe_title, safe_module, display_format, when, safe_title, ICON_MORE, safe_title, safe_module, safe_status, safe_title, safe_label, safe_imported, safe_error, safe_processing_stage, lib.ui.escapeSafe(req.allocator, processing_status), processing_when, when, if (std.mem.eql(u8, display_status, "Ready")) "good" else if (std.mem.eql(u8, display_status, "Pending") or std.mem.eql(u8, display_status, "Importing")) "info" else "warn", display_status });
    for (source.topic_tags) |topic| try w.print("<span>{s}</span> ", .{lib.ui.escapeSafe(req.allocator, topic)});
    try w.print("</span></div><div><button data-source-preview type=\"button\">Preview</button><a href=\"{s}\">{s} {s}</a></div></footer></article>", .{ safe_href, if (std.mem.startsWith(u8, href, "/")) "Ask with source" else "Open source", ICON_ARROW });
}

fn publicImportError(message: []const u8) []const u8 {
    if (std.mem.indexOf(u8, message, "Missing credentials") != null or
        std.mem.indexOf(u8, message, "OPENAI_API_KEY") != null or
        std.mem.indexOf(u8, message, "workload_identity") != null)
    {
        return "Indexing is not configured yet. Ask the workspace owner to connect the search service, then retry.";
    }
    return message;
}

fn renderMockSource(req: mer.Request, w: *std.Io.Writer, source: lib.types.WorkspaceSource, now_secs: i64) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, source.title);
    const safe_type = lib.ui.escapeSafe(req.allocator, source.source_type);
    const safe_module = lib.ui.escapeSafe(req.allocator, mockModuleCode(source.module_id));
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

fn mockModuleCode(module_id: []const u8) []const u8 {
    for (lib.mock.modules) |module| if (std.mem.eql(u8, module.id, module_id)) return module.code;
    return "Workspace";
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

fn renderDialogs(w: *std.Io.Writer, demo: bool) !void {
    try w.writeAll(
        \\<div class="modal-backdrop document-preview-backdrop" id="cp-source-preview-modal" hidden><section class="document-preview-modal" role="dialog" aria-modal="true" aria-labelledby="cp-preview-title"><button class="preview-close" type="button" data-close-source-modal aria-label="Close document preview">×</button><div class="preview-document-stage"><div class="document-paper expanded"><span class="paper-kicker">SOURCE METADATA</span><h3 id="cp-preview-paper-title">Source</h3><p class="paper-lede">This preview shows stored source metadata. Open the original source to inspect its content.</p><div class="paper-rule"></div><div class="scan-lines"><i></i><i></i><i></i><i></i></div></div></div><aside><p class="eyebrow">Source details</p><h2 id="cp-preview-title">Source</h2><p id="cp-preview-detail">Course material</p><span class="status-pill status-good" id="cp-preview-status">Ready</span><dl><div><dt>Context</dt><dd id="cp-preview-context">Workspace</dd></div><div><dt>Format</dt><dd id="cp-preview-format">Source</dd></div><div><dt>Topics</dt><dd id="cp-preview-topics">No topics assigned</dd></div></dl></aside></section></div>
        \\<div class="modal-backdrop" id="cp-add-source-modal" hidden><section class="source-modal source-intake-modal surface" role="dialog" aria-modal="true" aria-labelledby="cp-add-source-title"><button class="modal-close" type="button" data-close-source-modal aria-label="Close add source dialog">×</button><p class="eyebrow">Add evidence</p><h2 id="cp-add-source-title">Bring knowledge into your workspace.</h2><p class="source-intake-deck">Upload a document, save a reference link, or paste notes. WikiBase shows exactly what will be indexed.</p>
    );
    if (demo) {
        try w.writeAll("<div class=\"notice notice-info\"><strong>Illustrative demo</strong><span>Source imports are unavailable because no live account or storage is used.</span></div>");
    } else {
        try w.writeAll(
            \\<div class="source-mode-tabs" role="tablist" aria-label="Source type"><button type="button" role="tab" aria-selected="true" data-source-mode="upload">Upload files</button><button type="button" role="tab" aria-selected="false" data-source-mode="link">Add link</button><button type="button" role="tab" aria-selected="false" data-source-mode="paste">Paste text</button></div>
            \\<form id="cp-add-source-form" method="post" action="/api/sources/import"><input type="hidden" name="mode" value="upload"><div class="source-mode-panel" data-source-panel="upload"><label class="source-drop-zone" for="cp-source-files"><span>Drop PDF, image, Markdown, or text files here</span><small>PNG and JPEG images are read with OCR · up to 10 MiB each</small><input id="cp-source-files" name="files" type="file" accept="application/pdf,.pdf,image/png,.png,image/jpeg,.jpg,.jpeg,text/markdown,.md,text/plain,.txt" multiple required></label><ul class="source-file-list" aria-live="polite"></ul></div><div class="source-mode-panel" data-source-panel="link" hidden><div class="field"><label for="cp-new-source-url">Public link</label><input id="cp-new-source-url" name="url" type="url" placeholder="https://..." autocomplete="url"></div><p class="source-mode-note">Links are saved as searchable bookmark metadata. WikiBase does not claim to read or index the page.</p></div><div class="source-mode-panel" data-source-panel="paste" hidden><div class="field"><label for="cp-paste-format">Text format</label><select id="cp-paste-format" name="paste_format"><option value="plain_text">Plain text</option><option value="markdown">Markdown</option></select></div><div class="field"><label for="cp-source-content">Notes</label><textarea id="cp-source-content" name="content" rows="8" maxlength="2000000" placeholder="Paste lecture notes, a reading excerpt, or your own Markdown…"></textarea></div></div><div class="source-intake-fields"><div class="field"><label for="cp-new-source-title">Source title</label><input id="cp-new-source-title" name="title" placeholder="Derived from the file when left blank"></div><div class="field"><label for="cp-new-source-module">Module or context <span>optional</span></label><input id="cp-new-source-module" name="module" placeholder="e.g. CS2040S"></div></div><button class="button button-dark source-import-submit" type="submit">Import source</button><p class="cp-form-status" role="status" aria-live="polite"></p><noscript><p>File reading and secure import require JavaScript.</p></noscript></form>
        );
    }
    try w.writeAll("</section></div>");
}

test "source display formats preserve supported source types" {
    try std.testing.expectEqualStrings("URL", sourceDisplayFormat("link"));
    try std.testing.expectEqualStrings("PDF", sourceDisplayFormat("pdf"));
    try std.testing.expectEqualStrings("Image", sourceDisplayFormat("image"));
    try std.testing.expectEqualStrings("Markdown", sourceDisplayFormat("markdown"));
    try std.testing.expectEqualStrings("Text", sourceDisplayFormat("plain_text"));
    try std.testing.expectEqualStrings("Repository", sourceDisplayFormat("repository"));
    try std.testing.expectEqualStrings("Source", sourceDisplayFormat("future_type"));
}
