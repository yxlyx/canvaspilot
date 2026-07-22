const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "History", .description = "Review readable wiki version and citation changes." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "History")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
    const selected_type = req.queryParam("type") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("history render failed");
    w.writeAll("<header class=\"cp-page-header wb-m3-history-header\"><div><p class=\"cp-page-kicker\">Synthetic demo</p><h1 class=\"cp-page-title\">History</h1><p class=\"cp-page-sub\">Version timeline with citation changes and a readable unified diff.</p></div></header>") catch return mer.internalError("history render failed");
    w.writeAll("<nav class=\"cp-filter-row filter-row wb-m3-history-filters\" aria-label=\"Timeline filters\">") catch return mer.internalError("history render failed");
    filterLink(req, w, "All changes", "/history", std.mem.eql(u8, selected_type, "all")) catch return mer.internalError("history render failed");
    filterLink(req, w, "Content", "/history?type=content", std.mem.eql(u8, selected_type, "content")) catch return mer.internalError("history render failed");
    filterLink(req, w, "Citations", "/history?type=citations", std.mem.eql(u8, selected_type, "citations")) catch return mer.internalError("history render failed");
    w.writeAll("</nav><ol class=\"cp-timeline wb-m3-timeline\">") catch return mer.internalError("history render failed");
    var shown: usize = 0;
    for (lib.mock.history_changes) |change| {
        if (!std.mem.eql(u8, selected_type, "all") and !std.mem.eql(u8, selected_type, change.change_type)) continue;
        shown += 1;
        const title = lib.ui.escapeSafe(req.allocator, change.subject_title);
        const summary = lib.ui.escapeSafe(req.allocator, change.summary);
        const citation = lib.ui.escapeSafe(req.allocator, change.citation_change);
        const changed_at = lib.ui.escapeSafe(req.allocator, change.changed_at);
        w.print("<li><article class=\"cp-card surface wb-m3-history-card\"><div class=\"cp-card-title\"><h2>{s}</h2><span>v{d} → v{d}</span></div><p class=\"cp-muted-copy\">{s} change · {s}</p><p>{s}</p><p><strong>Citations:</strong> {s}</p><pre class=\"cp-diff wb-m3-diff\" aria-label=\"Unified diff\">", .{ title, change.version_from, change.version_to, change.change_type, changed_at, summary, citation }) catch return mer.internalError("history render failed");
        for (change.diff) |line| {
            const text = lib.ui.escapeSafe(req.allocator, line.text);
            w.print("<span class=\"cp-diff-{s}\">{s}</span>\n", .{ @tagName(line.kind), text }) catch return mer.internalError("history render failed");
        }
        w.writeAll("</pre><small class=\"cp-muted-copy\">Read-only revision preview</small></article></li>") catch return mer.internalError("history render failed");
    }
    if (shown == 0) w.writeAll("<li class=\"cp-empty wb-m3-empty\">No history entries match this filter.</li>") catch return mer.internalError("history render failed");
    w.writeAll("</ol>") catch return mer.internalError("history render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderLive(req: mer.Request) mer.Response {
    const result = lib.backend.history(req.allocator, lib.session.fromRequest(req).token);
    const entries = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Revision history", result.status);
    const selected_type = req.queryParam("type") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header wb-m3-history-header\"><div><h1 class=\"cp-page-title\">Workspace revision history</h1><p class=\"cp-page-sub\">Chronological backend-recorded changes. Current content remains authoritative.</p></div></header><nav class=\"cp-filter-row filter-row wb-m3-history-filters\" aria-label=\"History filters\">") catch return mer.internalError("history render failed");
    filterLink(req, w, "All", "/history", std.mem.eql(u8, selected_type, "all")) catch return mer.internalError("history render failed");
    filterLink(req, w, "Wiki revisions", "/history?type=wiki_revision", std.mem.eql(u8, selected_type, "wiki_revision")) catch return mer.internalError("history render failed");
    filterLink(req, w, "Source changes", "/history?type=source_change", std.mem.eql(u8, selected_type, "source_change")) catch return mer.internalError("history render failed");
    w.writeAll("</nav><ol class=\"cp-timeline wb-m3-timeline\">") catch return mer.internalError("history render failed");
    var shown: usize = 0;
    for (entries) |entry| {
        if (!std.mem.eql(u8, selected_type, "all") and !std.mem.eql(u8, selected_type, entry.entry_type)) continue;
        shown += 1;
        w.print("<li><article class=\"cp-card surface wb-m3-history-card\"><div class=\"cp-card-title\"><h2>{s}</h2><span>{s}</span></div><p>{s}</p>", .{ lib.ui.escapeSafe(req.allocator, entry.entry_type), lib.ui.escapeSafe(req.allocator, entry.created_at), lib.ui.escapeSafe(req.allocator, entry.summary) }) catch return mer.internalError("history render failed");
        if (std.mem.eql(u8, entry.entry_type, "wiki_revision")) w.print("<a class=\"cp-btn cp-btn-ghost button button-secondary\" href=\"/history?page={s}\">View revisions</a>", .{lib.ui.escapeSafe(req.allocator, entry.resource_id)}) catch return mer.internalError("history render failed");
        w.writeAll("</article></li>") catch return mer.internalError("history render failed");
    }
    if (shown == 0) w.writeAll("<li class=\"cp-empty wb-m3-empty\">No recorded changes match this filter.</li>") catch return mer.internalError("history render failed");
    w.writeAll("</ol>") catch return mer.internalError("history render failed");
    if (req.queryParam("page")) |page_id| if (std.mem.eql(u8, page_id, lib.m3.safeId(page_id, ""))) renderRevisions(req, w, page_id) catch return mer.internalError("revision render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderRevisions(req: mer.Request, w: *std.Io.Writer, page_id: []const u8) !void {
    const result = lib.backend.revisions(req.allocator, lib.session.fromRequest(req).token, page_id);
    if (result.value == null) {
        try w.writeAll("<section class=\"cp-card surface notice notice-info cp-unavailable wb-m3-unavailable\" role=\"alert\"><h2>Revisions unavailable</h2><p>The backend could not load this page revision history.</p></section>");
        return;
    }
    const revisions = result.value.?.value;
    try w.writeAll("<section class=\"cp-card surface wb-m3-revisions\"><h2>Page revisions</h2><ol class=\"cp-timeline wb-m3-timeline\">");
    for (revisions) |revision| try w.print("<li><strong>Revision {d} · {s}</strong><p>{s}</p><span>{d} citation(s) · {s}</span></li>", .{ revision.revision_number, lib.ui.escapeSafe(req.allocator, revision.title), lib.ui.escapeSafe(req.allocator, revision.change_summary), revision.citation_count, lib.ui.escapeSafe(req.allocator, revision.created_at) });
    if (revisions.len == 0) try w.writeAll("<li class=\"cp-empty wb-m3-empty\">No archived revisions; this page is current.</li>");
    try w.writeAll("</ol>");
    if (revisions.len >= 2) {
        const from = revisions[1].revision_number;
        const to = revisions[0].revision_number;
        const diff = lib.backend.revisionDiff(req.allocator, lib.session.fromRequest(req).token, page_id, from, to);
        if (diff.value) |parsed| {
            const bounded = parsed.value.diff[0..@min(parsed.value.diff.len, 100 * 1024)];
            try w.print("<h3>Bounded diff · revision {d} to {d}</h3><p class=\"cp-muted-copy\">Showing at most 100 KiB.</p><pre class=\"cp-diff wb-m3-diff\">{s}</pre>", .{ from, to, lib.ui.escapeSafe(req.allocator, bounded) });
        } else try w.writeAll("<p role=\"alert\">Diff unavailable for these revisions.</p>");
    }
    try w.writeAll("</section>");
}

fn filterLink(req: mer.Request, w: *std.Io.Writer, label: []const u8, path: []const u8, active: bool) !void {
    const href = try lib.m3.demoHref(req.allocator, req, path);
    const safe_href = lib.ui.escapeSafe(req.allocator, href);
    const current: []const u8 = if (active) " aria-current=\"page\"" else "";
    const class: []const u8 = if (active) " class=\"filter-button active cp-filter-active\"" else " class=\"filter-button\"";
    try w.print("<a{s} href=\"{s}\"{s}>{s}</a>", .{ class, safe_href, current, label });
}
