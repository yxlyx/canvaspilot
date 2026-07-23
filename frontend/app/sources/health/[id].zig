const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Health finding" };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Health finding")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const raw_id = req.param("id") orelse return renderMissing(req, "", demo);
    const id = lib.m3.safeId(raw_id, "");
    if (id.len == 0) return renderMissing(req, raw_id, demo);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("finding render failed");
    if (demo) {
        var found: ?lib.types.HealthFinding = null;
        for (lib.mock.health_findings) |finding| if (std.mem.eql(u8, finding.id, id)) {
            found = finding;
            break;
        };
        const finding = found orelse return renderMissing(req, id, true);
        w.print("<header class=\"cp-page-header\"><div><a class=\"article-breadcrumb\" href=\"/sources/health?mock=1\">← Health</a><p class=\"cp-page-kicker\">{s} · {s}</p><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">{s}</p></div></header><article class=\"cp-editorial-reader cp-finding-reader\"><div class=\"cp-reader-body\"><p class=\"eyebrow\">Finding</p><h2>What this means</h2><p>{s}</p><h2>Recommended action</h2><p>{s}</p></div><aside class=\"cp-reader-rail\"><dl><div><dt>Source</dt><dd>{s}</dd></div><div><dt>State</dt><dd>{s}</dd></div></dl></aside></article>", .{ @tagName(finding.severity), @tagName(finding.state), lib.ui.escapeSafe(req.allocator, finding.title), lib.ui.escapeSafe(req.allocator, finding.subject), lib.ui.escapeSafe(req.allocator, finding.detail), lib.ui.escapeSafe(req.allocator, finding.recommendation), lib.ui.escapeSafe(req.allocator, finding.subject), @tagName(finding.state) }) catch return mer.internalError("finding render failed");
    } else {
        const result = lib.backend.getHealth(req.allocator, lib.session.fromRequest(req).token, id);
        if (result.status == 404) return renderMissing(req, id, false);
        const finding = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Health finding", result.status);
        w.print("<header class=\"cp-page-header\"><div><a class=\"article-breadcrumb\" href=\"/sources/health\">← Health</a><p class=\"cp-page-kicker\">{s} · {s}</p><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Checked {s}</p></div></header><article class=\"cp-editorial-reader cp-finding-reader\"><div class=\"cp-reader-body\"><h2>Explanation</h2><p>{s}</p><h2>Recommended action</h2><p>{s}</p></div><aside class=\"cp-reader-rail\"><dl><div><dt>Resource</dt><dd>{s}</dd></div><div><dt>Topic</dt><dd>{s}</dd></div></dl></aside></article>", .{ lib.ui.escapeSafe(req.allocator, finding.severity), lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.code), lib.ui.escapeSafe(req.allocator, finding.created_at), lib.ui.escapeSafe(req.allocator, finding.message), lib.ui.escapeSafe(req.allocator, finding.recommendation), lib.ui.escapeSafe(req.allocator, finding.resource_type), lib.ui.escapeSafe(req.allocator, finding.topic orelse "Not topic-specific") }) catch return mer.internalError("finding render failed");
    }
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderMissing(req: mer.Request, id: []const u8, demo: bool) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("finding state render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Source integrity</p><h1 class=\"cp-page-title\">Finding not found</h1><p class=\"cp-page-sub\">This finding does not exist or is no longer current.</p></div></header>") catch return mer.internalError("finding state render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.source_tabs, "health", "Sources", demo) catch return mer.internalError("finding state tabs failed");
    const href = lib.m3.demoHrefFor(req.allocator, demo, "/sources/health") catch return mer.internalError("finding state link failed");
    w.print("<section class=\"cp-boundary\" role=\"status\"><p class=\"eyebrow\">No current finding</p><h2>Nothing needs review at this address.</h2><p>No source-health record matches <strong>{s}</strong>.</p><a class=\"cp-btn cp-btn-ghost\" href=\"{s}\">Return to Health</a></section>", .{ lib.ui.escapeSafe(req.allocator, id), href }) catch return mer.internalError("finding state render failed");
    var response = lib.ui.htmlResponse(&buf);
    response.status = .not_found;
    return lib.m3.privateForSession(req, response);
}
