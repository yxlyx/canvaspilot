const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Source health", .description = "Review source coverage, freshness, and processing findings." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Source health")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const selected = req.queryParam("severity") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("health render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Source integrity</p><h1 class=\"cp-page-title\">Health</h1><p class=\"cp-page-sub\">Coverage, freshness, and processing issues that need a closer look.</p></div>") catch return mer.internalError("health render failed");
    if (!demo) w.writeAll("<form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"/sources/health\"><input type=\"hidden\" name=\"action\" value=\"health.run\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Run checks</button><span class=\"cp-form-status\" role=\"status\"></span></form>") catch return mer.internalError("health render failed");
    w.writeAll("</header>") catch return mer.internalError("health render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.source_tabs, "health", "Sources", demo) catch return mer.internalError("health tabs failed");
    if (demo) {
        const summary = lib.mock.health_summary;
        w.print("<section class=\"cp-attention-summary\" aria-label=\"Health summary\"><p><strong>{d} healthy</strong><span>Current and supported</span></p><p><strong>{d} need attention</strong><span>Thin or stale coverage</span></p><p><strong>{d} failed</strong><span>Processing or reference errors</span></p><p><strong>{d} unknown</strong><span>Not checked yet</span></p></section>", .{ summary.healthy, summary.warning + summary.stale, summary.failed, summary.unknown }) catch return mer.internalError("health render failed");
    } else {
        w.writeAll("<section class=\"cp-attention-summary\" aria-label=\"Health summary\"><p><strong>Health findings</strong><span>Resolve failed processing first, then improve thin or stale coverage.</span></p></section>") catch return mer.internalError("health render failed");
    }
    w.writeAll("<nav class=\"cp-filter-row\" aria-label=\"Health status\">") catch return mer.internalError("health render failed");
    filter(req, w, "All", "all", selected, demo) catch return mer.internalError("health render failed");
    filter(req, w, "Healthy", "info", selected, demo) catch return mer.internalError("health render failed");
    filter(req, w, "Warning", "warning", selected, demo) catch return mer.internalError("health render failed");
    filter(req, w, "Failed", "error", selected, demo) catch return mer.internalError("health render failed");
    w.writeAll("</nav><section class=\"cp-editorial-ledger cp-health-ledger\" aria-label=\"Findings\">") catch return mer.internalError("health render failed");
    var shown: usize = 0;
    if (demo) {
        for (lib.mock.health_findings) |finding| {
            const matches = std.mem.eql(u8, selected, "all") or std.mem.eql(u8, selected, @tagName(finding.severity)) or (std.mem.eql(u8, selected, "error") and finding.severity == .critical);
            if (!matches) continue;
            shown += 1;
            const path = std.fmt.allocPrint(req.allocator, "/sources/health/{s}", .{lib.m3.safeId(finding.id, "")}) catch return mer.internalError("health render failed");
            const href = lib.m3.demoHrefFor(req.allocator, true, path) catch return mer.internalError("health render failed");
            w.print("<article><div><span class=\"cp-state status-pill\">{s}</span><h2><a href=\"{s}\">{s}</a></h2><p>{s}</p></div><div><strong>{s}</strong><p>{s}</p></div></article>", .{ @tagName(finding.state), href, lib.ui.escapeSafe(req.allocator, finding.title), lib.ui.escapeSafe(req.allocator, finding.detail), lib.ui.escapeSafe(req.allocator, finding.subject), lib.ui.escapeSafe(req.allocator, finding.recommendation) }) catch return mer.internalError("health render failed");
        }
    } else {
        const result = lib.backend.listHealth(req.allocator, lib.session.fromRequest(req).token);
        const findings = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Source health", result.status);
        for (findings) |finding| {
            if (!std.mem.eql(u8, selected, "all") and !std.mem.eql(u8, selected, finding.severity)) continue;
            shown += 1;
            w.print("<article><div><span class=\"cp-state status-pill\">{s} · {s}</span><h2><a href=\"/sources/health/{s}\">{s}</a></h2><p>{s}</p></div><div><strong>Recommended action</strong><p>{s}</p></div></article>", .{ lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.severity), lib.ui.escapeSafe(req.allocator, finding.id), lib.ui.escapeSafe(req.allocator, finding.code), lib.ui.escapeSafe(req.allocator, finding.message), lib.ui.escapeSafe(req.allocator, finding.recommendation) }) catch return mer.internalError("health render failed");
        }
    }
    if (shown == 0) w.writeAll("<div class=\"cp-empty\"><div><h2>No findings here</h2><p>There are no source findings for this status.</p></div></div>") catch return mer.internalError("health render failed");
    w.writeAll("</section><script src=\"/m3.js?v=20260722\" defer></script>") catch return mer.internalError("health render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn filter(req: mer.Request, w: *std.Io.Writer, label: []const u8, value: []const u8, selected: []const u8, demo: bool) !void {
    const path = if (std.mem.eql(u8, value, "all")) "/sources/health" else try std.fmt.allocPrint(req.allocator, "/sources/health?severity={s}", .{value});
    const href = try lib.m3.demoHrefFor(req.allocator, demo, path);
    try w.print("<a class=\"filter-button{s}\" href=\"{s}\"{s}>{s}</a>", .{ if (std.mem.eql(u8, value, selected)) " active" else "", href, if (std.mem.eql(u8, value, selected)) " aria-current=\"page\"" else "", label });
}
