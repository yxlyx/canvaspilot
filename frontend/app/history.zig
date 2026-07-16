const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "History", .description = "Review readable wiki version and citation changes." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "History")) |response| return response;
    const selected_type = req.queryParam("type") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">History</h1><p class=\"cp-page-sub\">Version timeline with citation changes and a readable unified diff.</p></div></header>") catch return mer.internalError("history render failed");
    lib.m3.demoBanner(req, w) catch return mer.internalError("history render failed");
    w.writeAll("<nav class=\"cp-filter-row\" aria-label=\"Timeline filters\">") catch return mer.internalError("history render failed");
    filterLink(req, w, "All changes", "/history", std.mem.eql(u8, selected_type, "all")) catch return mer.internalError("history render failed");
    filterLink(req, w, "Content", "/history?type=content", std.mem.eql(u8, selected_type, "content")) catch return mer.internalError("history render failed");
    filterLink(req, w, "Citations", "/history?type=citations", std.mem.eql(u8, selected_type, "citations")) catch return mer.internalError("history render failed");
    w.writeAll("</nav><ol class=\"cp-timeline\">") catch return mer.internalError("history render failed");
    var shown: usize = 0;
    for (lib.mock.history_changes) |change| {
        if (!std.mem.eql(u8, selected_type, "all") and !std.mem.eql(u8, selected_type, change.change_type)) continue;
        shown += 1;
        const title = lib.ui.escapeSafe(req.allocator, change.subject_title);
        const summary = lib.ui.escapeSafe(req.allocator, change.summary);
        const citation = lib.ui.escapeSafe(req.allocator, change.citation_change);
        const changed_at = lib.ui.escapeSafe(req.allocator, change.changed_at);
        const change_id = lib.m3.safeId(change.id, "history-change");
        w.print("<li><article class=\"cp-card\"><div class=\"cp-card-title\"><h2>{s}</h2><span>v{d} → v{d}</span></div><p class=\"cp-muted-copy\">{s} change · {s}</p><p>{s}</p><p><strong>Citations:</strong> {s}</p><pre class=\"cp-diff\" aria-label=\"Unified diff\">", .{ title, change.version_from, change.version_to, change.change_type, changed_at, summary, citation }) catch return mer.internalError("history render failed");
        for (change.diff) |line| {
            const text = lib.ui.escapeSafe(req.allocator, line.text);
            w.print("<span class=\"cp-diff-{s}\">{s}</span>\n", .{ @tagName(line.kind), text }) catch return mer.internalError("history render failed");
        }
        w.print("</pre><button class=\"cp-btn cp-btn-ghost\" type=\"button\" aria-disabled=\"true\" aria-describedby=\"history-note-{s}\">Restore version</button><small id=\"history-note-{s}\">Restore is unavailable until a backend mutation contract exists.</small></article></li>", .{ change_id, change_id }) catch return mer.internalError("history render failed");
    }
    if (shown == 0) w.writeAll("<li class=\"cp-empty\">No history entries match this filter.</li>") catch return mer.internalError("history render failed");
    w.writeAll("</ol>") catch return mer.internalError("history render failed");
    return lib.ui.htmlResponse(&buf);
}

fn filterLink(req: mer.Request, w: *std.Io.Writer, label: []const u8, path: []const u8, active: bool) !void {
    const href = try lib.m3.demoHref(req.allocator, req, path);
    const safe_href = lib.ui.escapeSafe(req.allocator, href);
    const current: []const u8 = if (active) " aria-current=\"page\"" else "";
    const class: []const u8 = if (active) " class=\"cp-filter-active\"" else "";
    try w.print("<a{s} href=\"{s}\"{s}>{s}</a>", .{ class, safe_href, current, label });
}
