const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");
pub const meta: mer.Meta = .{ .title = "Health finding" };

fn detailState(req: mer.Request, status: std.http.Status, title: []const u8, message: []const u8) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    buf.writer.print("<div class=\"wb-m3-page wb-m3-health-detail page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><a class=\"wb-m3-back-link\" href=\"/health\">← Workspace health</a><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Health finding detail</p></div></header><section class=\"cp-card cp-unavailable surface wb-m3-detail-state\" role=\"alert\"><p>{s}</p><a class=\"cp-btn cp-btn-ghost\" href=\"/health\">Return to workspace health</a></section></div>", .{ title, message }) catch return mer.internalError("finding state render failed");
    var response = lib.ui.htmlResponse(&buf);
    response.status = status;
    return lib.m3.privateForSession(req, response);
}

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Health finding")) |r| return r;
    if (lib.m3.isExplicitDemo(req)) return mer.redirect("/health?mock=1", .see_other);
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
