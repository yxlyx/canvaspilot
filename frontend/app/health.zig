const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Workspace health", .description = "Review citation, freshness, and source health findings." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Workspace health")) |response| return response;
    const selected = req.queryParam("severity") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">Workspace health</h1><p class=\"cp-page-sub\">Structured checks for citation coverage, stale pages, and failed references.</p></div><button class=\"cp-btn cp-btn-primary\" type=\"button\" disabled>Run checks</button></header>") catch return mer.internalError("health render failed");
    lib.m3.demoBanner(w) catch return mer.internalError("health render failed");
    const summary = lib.mock.health_summary;
    w.print("<section class=\"cp-health-summary\" aria-label=\"Health summary\"><div>healthy <strong>{d}</strong></div><div>warning <strong>{d}</strong></div><div>failed <strong>{d}</strong></div><div>stale <strong>{d}</strong></div><div>unknown <strong>{d}</strong></div></section>", .{ summary.healthy, summary.warning, summary.failed, summary.stale, summary.unknown }) catch return mer.internalError("health render failed");
    w.writeAll("<nav class=\"cp-filter-row\" aria-label=\"Severity filter\"><a href=\"/health?mock=1\">All</a><a href=\"/health?mock=1&amp;severity=info\">Info</a><a href=\"/health?mock=1&amp;severity=warning\">Warning</a><a href=\"/health?mock=1&amp;severity=error\">Error</a></nav><section class=\"cp-list-grid\">") catch return mer.internalError("health render failed");
    var shown: usize = 0;
    for (lib.mock.health_findings) |finding| {
        const matches = std.mem.eql(u8, selected, @tagName(finding.severity)) or (std.mem.eql(u8, selected, "error") and finding.severity == .critical);
        if (!std.mem.eql(u8, selected, "all") and !matches) continue;
        shown += 1;
        const title = lib.ui.escape(req.allocator, finding.title) catch finding.title;
        const detail = lib.ui.escape(req.allocator, finding.detail) catch finding.detail;
        const subject = lib.ui.escape(req.allocator, finding.subject) catch finding.subject;
        const recommendation = lib.ui.escape(req.allocator, finding.recommendation) catch finding.recommendation;
        w.print("<article class=\"cp-card cp-finding\"><div><span class=\"cp-state cp-state-{s}\">{s}</span> <span>{s}</span></div><h2>{s}</h2><p>{s}</p><p><strong>Recommendation:</strong> {s}</p></article>", .{ @tagName(finding.state), @tagName(finding.state), subject, title, detail, recommendation }) catch return mer.internalError("health render failed");
    }
    if (shown == 0) w.writeAll("<div class=\"cp-empty\">No findings match this severity.</div>") catch return mer.internalError("health render failed");
    w.writeAll("</section>") catch return mer.internalError("health render failed");
    return lib.ui.htmlResponse(&buf);
}
