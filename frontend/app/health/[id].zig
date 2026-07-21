const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");
pub const meta: mer.Meta = .{ .title = "Health finding" };
pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Health finding")) |r| return r;
    if (lib.m3.isExplicitDemo(req)) return mer.redirect("/health?mock=1", .see_other);
    const id = req.param("id") orelse return mer.notFound();
    if (!std.mem.eql(u8, id, lib.m3.safeId(id, ""))) return mer.notFound();
    const result = lib.backend.getHealth(req.allocator, lib.session.fromRequest(req).token, id);
    if (result.status == 404) return mer.notFound();
    const finding = if (result.value) |p| p.value else return lib.m3.liveError(req, "Health finding", result.status);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.print("<header class=\"cp-page-header\"><div><a href=\"/health\">← Workspace health</a><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Current {s} finding · {s}</p></div></header><article class=\"cp-card\"><p><strong>State:</strong> {s}</p><p>{s}</p><h2>Remediation</h2><p>{s}</p><dl><dt>Resource type</dt><dd>{s}</dd><dt>Topic</dt><dd>{s}</dd><dt>Checked</dt><dd>{s}</dd></dl></article>", .{ lib.ui.escapeSafe(req.allocator, finding.code), lib.ui.escapeSafe(req.allocator, finding.severity), lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.message), lib.ui.escapeSafe(req.allocator, finding.recommendation), lib.ui.escapeSafe(req.allocator, finding.resource_type), lib.ui.escapeSafe(req.allocator, finding.topic orelse "Not topic-specific"), lib.ui.escapeSafe(req.allocator, finding.created_at) }) catch return mer.internalError("finding render failed");
    return lib.ui.htmlResponse(&buf);
}
