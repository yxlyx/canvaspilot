const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Workspace health", .description = "Review citation, freshness, and source health findings." };

pub fn render(req: mer.Request) mer.Response {
    return lib.navigation.redirectPreservingQuery(req, "/sources/health");
}

fn legacyRender(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Workspace health")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
    const selected = req.queryParam("severity") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("health render failed");
    w.writeAll("<div class=\"wb-m3-page wb-m3-health page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><p class=\"cp-page-kicker\">Synthetic demo</p><h1 class=\"cp-page-title\">Workspace health</h1><p class=\"cp-page-sub\">A labelled snapshot of citation coverage, stale pages, and failed references. No live check is running.</p></div></header>") catch return mer.internalError("health render failed");
    const summary = lib.mock.health_summary;
    w.print("<section class=\"cp-health-summary cp-metric-grid wb-m3-health-summary\" aria-label=\"Health summary\"><div class=\"cp-metric-card wb-m3-health-metric\"><span class=\"cp-metric-label\">healthy</span><strong class=\"cp-metric-value\">{d}</strong></div><div class=\"cp-metric-card wb-m3-health-metric\"><span class=\"cp-metric-label\">warning</span><strong class=\"cp-metric-value\">{d}</strong></div><div class=\"cp-metric-card wb-m3-health-metric\"><span class=\"cp-metric-label\">failed</span><strong class=\"cp-metric-value\">{d}</strong></div><div class=\"cp-metric-card wb-m3-health-metric\"><span class=\"cp-metric-label\">stale</span><strong class=\"cp-metric-value\">{d}</strong></div><div class=\"cp-metric-card wb-m3-health-metric\"><span class=\"cp-metric-label\">unknown</span><strong class=\"cp-metric-value\">{d}</strong></div></section>", .{ summary.healthy, summary.warning, summary.failed, summary.stale, summary.unknown }) catch return mer.internalError("health render failed");
    w.writeAll("<nav class=\"cp-filter-row wb-m3-filters\" aria-label=\"Severity filter\">") catch return mer.internalError("health render failed");
    filterLink(req, w, "All", "/health", std.mem.eql(u8, selected, "all")) catch return mer.internalError("health render failed");
    filterLink(req, w, "Info", "/health?severity=info", std.mem.eql(u8, selected, "info")) catch return mer.internalError("health render failed");
    filterLink(req, w, "Warning", "/health?severity=warning", std.mem.eql(u8, selected, "warning")) catch return mer.internalError("health render failed");
    filterLink(req, w, "Error", "/health?severity=error", std.mem.eql(u8, selected, "error")) catch return mer.internalError("health render failed");
    w.writeAll("</nav><section class=\"cp-list-grid wb-m3-findings\">") catch return mer.internalError("health render failed");
    var shown: usize = 0;
    for (lib.mock.health_findings) |finding| {
        const matches = std.mem.eql(u8, selected, @tagName(finding.severity)) or (std.mem.eql(u8, selected, "error") and finding.severity == .critical);
        if (!std.mem.eql(u8, selected, "all") and !matches) continue;
        shown += 1;
        const title = lib.ui.escapeSafe(req.allocator, finding.title);
        const detail = lib.ui.escapeSafe(req.allocator, finding.detail);
        const subject = lib.ui.escapeSafe(req.allocator, finding.subject);
        const recommendation = lib.ui.escapeSafe(req.allocator, finding.recommendation);
        const action_label = lib.ui.escapeSafe(req.allocator, finding.action_label);
        const internal_href = lib.m3.safeInternalHref(finding.action_href, "/health");
        const demo_href = lib.m3.demoHref(req.allocator, req, internal_href) catch return mer.internalError("health render failed");
        const action_href = lib.ui.escapeSafe(req.allocator, demo_href);
        w.print("<article class=\"cp-card cp-finding surface wb-m3-finding\"><div><span class=\"cp-state cp-state-{s} status-pill wb-m3-state\">{s}</span> <span>{s}</span></div><h2><a href=\"/health/{s}?mock=1\">{s}</a></h2><p>{s}</p><p><strong>Recommendation:</strong> {s}</p><a class=\"cp-btn cp-btn-ghost\" href=\"{s}\">{s}</a></article>", .{ @tagName(finding.state), @tagName(finding.state), subject, lib.m3.safeId(finding.id, ""), title, detail, recommendation, action_href, action_label }) catch return mer.internalError("health render failed");
    }
    if (shown == 0) w.writeAll("<div class=\"cp-empty wb-m3-empty\">No findings match this severity.</div>") catch return mer.internalError("health render failed");
    w.writeAll("</section></div>") catch return mer.internalError("health render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderLive(req: mer.Request) mer.Response {
    const result = lib.backend.listHealth(req.allocator, lib.session.fromRequest(req).token);
    const findings = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Workspace health", result.status);
    const severity = req.queryParam("severity") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<div class=\"wb-m3-page wb-m3-health page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><h1 class=\"cp-page-title\">Workspace health</h1><p class=\"cp-page-sub\">Current backend checks for stale, failed, warning, unknown, and healthy resources.</p></div><form class=\"wb-m3-run-form\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"/health\"><input type=\"hidden\" name=\"action\" value=\"health.run\"><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Rerun health checks</button><span class=\"cp-form-status\" role=\"status\"></span></form></header><nav class=\"cp-filter-row wb-m3-filters\" aria-label=\"Severity filter\">") catch return mer.internalError("health render failed");
    filterLink(req, w, "All", "/health", std.mem.eql(u8, severity, "all")) catch return mer.internalError("health render failed");
    filterLink(req, w, "Info", "/health?severity=info", std.mem.eql(u8, severity, "info")) catch return mer.internalError("health render failed");
    filterLink(req, w, "Warning", "/health?severity=warning", std.mem.eql(u8, severity, "warning")) catch return mer.internalError("health render failed");
    filterLink(req, w, "Error", "/health?severity=error", std.mem.eql(u8, severity, "error")) catch return mer.internalError("health render failed");
    w.writeAll("</nav><section class=\"cp-list-grid wb-m3-findings\">") catch return mer.internalError("health render failed");
    var shown: usize = 0;
    for (findings) |finding| {
        if (!std.mem.eql(u8, severity, "all") and !std.mem.eql(u8, severity, finding.severity)) continue;
        shown += 1;
        w.print("<article class=\"cp-card cp-finding surface wb-m3-finding\"><span class=\"cp-state cp-state-{s} status-pill wb-m3-state\">{s} · {s}</span><h2>{s}</h2><p>{s}</p><p><strong>Remediation:</strong> {s}</p><a class=\"cp-btn cp-btn-ghost\" href=\"/health/{s}\">Finding detail</a></article>", .{ lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.severity), lib.ui.escapeSafe(req.allocator, finding.code), lib.ui.escapeSafe(req.allocator, finding.message), lib.ui.escapeSafe(req.allocator, finding.recommendation), lib.ui.escapeSafe(req.allocator, finding.id) }) catch return mer.internalError("health render failed");
    }
    if (shown == 0) w.writeAll(if (findings.len == 0) "<div class=\"cp-empty wb-m3-empty\"><h2>No current findings</h2><p>Run health checks to establish the current workspace state.</p></div>" else "<div class=\"cp-empty wb-m3-empty\">No findings match this filter.</div>") catch return mer.internalError("health render failed");
    w.writeAll("</section><script src=\"/m3.js?v=20260721\" defer></script></div>") catch return mer.internalError("health render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn filterLink(req: mer.Request, w: *std.Io.Writer, label: []const u8, path: []const u8, active: bool) !void {
    const href = try lib.m3.demoHref(req.allocator, req, path);
    const safe_href = lib.ui.escapeSafe(req.allocator, href);
    const current: []const u8 = if (active) " aria-current=\"page\"" else "";
    const class: []const u8 = if (active) " class=\"cp-chip cp-chip-active cp-filter-active\"" else " class=\"cp-chip\"";
    try w.print("<a{s} href=\"{s}\"{s}>{s}</a>", .{ class, safe_href, current, label });
}
