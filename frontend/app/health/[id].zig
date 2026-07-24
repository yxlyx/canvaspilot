const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");
pub const meta: mer.Meta = .{ .title = "Health finding" };

fn detailState(req: mer.Request, status: std.http.Status, title: []const u8, message: []const u8) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    lib.m3.demoMarker(req, &buf.writer) catch return mer.internalError("finding state render failed");
    buf.writer.print("<div class=\"wb-m3-page wb-m3-health-detail page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><a class=\"wb-m3-back-link\" href=\"/health\">← Workspace health</a><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Health finding detail</p></div></header><section class=\"cp-card cp-unavailable surface wb-m3-detail-state\" role=\"alert\"><p>{s}</p><a class=\"cp-btn cp-btn-ghost\" href=\"/health\">Return to workspace health</a></section></div>", .{ title, message }) catch return mer.internalError("finding state render failed");
    var response = lib.ui.htmlResponse(&buf);
    response.status = status;
    return lib.m3.privateForSession(req, response);
}

pub fn render(req: mer.Request) mer.Response {
    const id = req.param("id") orelse return lib.m3.privateForSession(req, mer.notFound());
    if (!std.mem.eql(u8, id, lib.m3.safeId(id, ""))) return lib.m3.privateForSession(req, mer.notFound());
    const destination = std.fmt.allocPrint(req.allocator, "/sources/health/{s}", .{id}) catch "/sources/health";
    return lib.navigation.redirectPreservingQuery(req, destination);
}

fn legacyRender(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Health finding")) |r| return r;
    if (lib.m3.isExplicitDemo(req)) return renderDemo(req);
    const id = req.param("id") orelse return detailState(req, .bad_request, "Invalid health finding", "The finding ID is missing or malformed.");
    if (!std.mem.eql(u8, id, lib.m3.safeId(id, ""))) return detailState(req, .bad_request, "Invalid health finding", "The finding ID is malformed. No health service request was made.");
    const result = lib.backend.getHealth(req.allocator, lib.session.fromRequest(req).token, id);
    if (result.status == 404) return detailState(req, .not_found, "Health finding not found", "This finding does not exist or is no longer current.");
    const finding = if (result.value) |p| p.value else return lib.m3.liveError(req, "Health finding", result.status);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.print("<div class=\"wb-m3-page wb-m3-health-detail page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><a class=\"wb-m3-back-link\" href=\"/health\">← Workspace health</a><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Current {s} finding · {s}</p></div></header><article class=\"cp-card surface wb-m3-detail-card\"><p><strong>State:</strong> <span class=\"cp-state status-pill wb-m3-state\">{s}</span></p><p>{s}</p><h2>Remediation</h2><p>{s}</p><dl class=\"cp-facts wb-m3-facts\"><div><dt>Resource type</dt><dd>{s}</dd></div><div><dt>Topic</dt><dd>{s}</dd></div><div><dt>Checked</dt><dd>{s}</dd></div></dl></article></div>", .{ lib.ui.escapeSafe(req.allocator, finding.code), lib.ui.escapeSafe(req.allocator, finding.severity), lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.message), lib.ui.escapeSafe(req.allocator, finding.recommendation), lib.ui.escapeSafe(req.allocator, finding.resource_type), lib.ui.escapeSafe(req.allocator, finding.topic orelse "Not topic-specific"), lib.ui.escapeSafe(req.allocator, finding.created_at) }) catch return mer.internalError("finding render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderDemo(req: mer.Request) mer.Response {
    const id = req.param("id") orelse "";
    var match: ?lib.types.HealthFinding = null;
    for (lib.mock.health_findings) |finding| if (std.mem.eql(u8, finding.id, id)) {
        match = finding;
        break;
    };
    const finding = match orelse return detailState(req, .not_found, "Health finding not found", "No synthetic finding matches this address.");
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("finding render failed");
    w.print("<div class=\"wb-m3-page wb-m3-health-detail page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><a class=\"wb-m3-back-link\" href=\"/health?mock=1\">← Workspace health</a><p class=\"cp-page-kicker\">Synthetic demo</p><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">{s} · {s}</p></div></header><article class=\"cp-card surface wb-m3-detail-card\"><span class=\"cp-state cp-state-{s} status-pill wb-m3-state\">{s}</span><div><p>{s}</p><h2>Recommendation</h2><p>{s}</p></div><dl class=\"cp-facts wb-m3-facts\"><div><dt>Subject</dt><dd>{s}</dd></div><div><dt>Severity</dt><dd>{s}</dd></div></dl></article></div>", .{ lib.ui.escapeSafe(req.allocator, finding.title), @tagName(finding.state), @tagName(finding.severity), @tagName(finding.state), @tagName(finding.state), lib.ui.escapeSafe(req.allocator, finding.detail), lib.ui.escapeSafe(req.allocator, finding.recommendation), lib.ui.escapeSafe(req.allocator, finding.subject), @tagName(finding.severity) }) catch return mer.internalError("finding render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
