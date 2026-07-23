const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Study guide" };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Study guide")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const raw_id = req.param("id") orelse return renderMissing(req, "", demo);
    const id = lib.m3.safeId(raw_id, "");
    if (id.len == 0) return renderMissing(req, raw_id, demo);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("guide render failed");
    if (demo) {
        if (!std.mem.eql(u8, id, lib.mock.output.id)) return renderMissing(req, id, true);
        const output = lib.mock.output;
        w.print("<header class=\"cp-page-header\"><div><a class=\"article-breadcrumb\" href=\"/wiki/guides?mock=1\">← Study guides</a><p class=\"cp-page-kicker\">Grounded guide</p><h1 class=\"cp-page-title\">{s}</h1></div></header><article class=\"cp-editorial-reader cp-guide-reader\"><div class=\"cp-reader-body cp-markdown\"><p>{s}</p><h2>Key ideas</h2><p>Review each claim against its cited source before using it as evidence.</p></div><aside class=\"cp-reader-rail\"><p class=\"eyebrow\">Evidence</p><ol class=\"cp-citation-list\">", .{ lib.ui.escapeSafe(req.allocator, output.title), lib.ui.escapeSafe(req.allocator, output.summary) }) catch return mer.internalError("guide render failed");
        for (output.citations) |citation| w.print("<li><strong>{s}</strong><small>{s}</small><p>{s}</p></li>", .{ lib.ui.escapeSafe(req.allocator, citation.source_title), lib.ui.escapeSafe(req.allocator, citation.location), lib.ui.escapeSafe(req.allocator, citation.snippet) }) catch return mer.internalError("guide render failed");
    } else {
        const result = lib.backend.getOutput(req.allocator, lib.session.fromRequest(req).token, id);
        if (result.status == 404) return renderMissing(req, id, false);
        const output = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Study guide", result.status);
        w.print("<header class=\"cp-page-header\"><div><a class=\"article-breadcrumb\" href=\"/wiki/guides\">← Study guides</a><p class=\"cp-page-kicker\">{s}</p><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">{s}</p></div></header><article class=\"cp-editorial-reader cp-guide-reader\"><div class=\"cp-reader-body cp-markdown\">", .{ lib.ui.escapeSafe(req.allocator, output.status), lib.ui.escapeSafe(req.allocator, output.title), lib.ui.escapeSafe(req.allocator, output.message) }) catch return mer.internalError("guide render failed");
        if (std.mem.eql(u8, output.status, "grounded") or std.mem.eql(u8, output.status, "completed")) {
            lib.markdown.renderMarkdown(req.allocator, w, output.content) catch return mer.internalError("guide markdown failed");
        } else {
            w.writeAll("<div class=\"cp-boundary\"><h2>No unsupported guide was created</h2><p>The selected evidence could not support this guide. Adjust the scope and try again.</p></div>") catch return mer.internalError("guide render failed");
        }
        w.writeAll("</div><aside class=\"cp-reader-rail\"><p class=\"eyebrow\">Evidence</p><ol class=\"cp-citation-list\">") catch return mer.internalError("guide render failed");
        for (output.citations) |citation| w.print("<li><strong>{s}</strong><small>{s}</small><p>{s}</p></li>", .{ lib.ui.escapeSafe(req.allocator, citation.source_title), lib.ui.escapeSafe(req.allocator, citation.citation_ref), lib.ui.escapeSafe(req.allocator, citation.snippet) }) catch return mer.internalError("guide render failed");
    }
    w.writeAll("</ol></aside></article>") catch return mer.internalError("guide render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderMissing(req: mer.Request, id: []const u8, demo: bool) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("guide state render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Grounded synthesis</p><h1 class=\"cp-page-title\">Study guide not found</h1><p class=\"cp-page-sub\">No saved guide matches this address.</p></div></header>") catch return mer.internalError("guide state render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.wiki_tabs, "guides", "Wiki", demo) catch return mer.internalError("guide state tabs failed");
    const href = lib.m3.demoHrefFor(req.allocator, demo, "/wiki/guides") catch return mer.internalError("guide state link failed");
    w.print("<section class=\"cp-boundary\" role=\"status\"><p class=\"eyebrow\">No saved guide</p><h2>Nothing was generated or substituted.</h2><p>No study-guide record matches <strong>{s}</strong>.</p><a class=\"cp-btn cp-btn-ghost\" href=\"{s}\">Return to Study guides</a></section>", .{ lib.ui.escapeSafe(req.allocator, id), href }) catch return mer.internalError("guide state render failed");
    var response = lib.ui.htmlResponse(&buf);
    response.status = .not_found;
    return lib.m3.privateForSession(req, response);
}
