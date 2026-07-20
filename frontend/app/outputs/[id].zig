const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");
pub const meta: mer.Meta = .{ .title = "Output detail", .description = "Review a grounded cited study output." };
pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Output detail")) |response| return response;
    if (lib.m3.isExplicitDemo(req)) return mer.redirect("/outputs?mock=1", .see_other);
    const id = req.param("id") orelse return mer.notFound();
    if (!std.mem.eql(u8, id, lib.m3.safeId(id, ""))) return mer.notFound();
    const result = lib.backend.getOutput(req.allocator, lib.session.fromRequest(req).token, id);
    if (result.status == 404) return mer.notFound();
    const output = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Output detail", result.status);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const state = if (std.mem.eql(u8, output.status, "insufficient_evidence")) "Insufficient evidence" else if (std.mem.eql(u8, output.status, "provider_unavailable")) "Provider unavailable" else output.status;
    w.print("<header class=\"cp-page-header\"><div><a href=\"/outputs\">← All outputs</a><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">{s} · {s}</p></div></header><section class=\"cp-card cp-boundary\"><strong>{s}</strong><p>{s}</p></section>", .{ lib.ui.escapeSafe(req.allocator, output.title), lib.ui.escapeSafe(req.allocator, output.output_type), lib.ui.escapeSafe(req.allocator, state), lib.ui.escapeSafe(req.allocator, state), lib.ui.escapeSafe(req.allocator, output.message) }) catch return mer.internalError("output render failed");
    if (std.mem.eql(u8, output.status, "grounded") or std.mem.eql(u8, output.status, "completed")) {
        w.writeAll("<article class=\"cp-card cp-markdown\">") catch return mer.internalError("output render failed");
        lib.markdown.renderMarkdown(req.allocator, w, output.content) catch return mer.internalError("output markdown failed");
        w.writeAll("</article>") catch return mer.internalError("output render failed");
    }
    w.writeAll("<section class=\"cp-card\" aria-labelledby=\"citations-title\"><h2 id=\"citations-title\">Grounded citations</h2><ol class=\"cp-citation-list\">") catch return mer.internalError("output render failed");
    for (output.citations) |citation| w.print("<li class=\"cp-citation-card\"><strong>{s}</strong><small>{s}</small><p>{s}</p><a href=\"/sources\">Open source library</a></li>", .{ lib.ui.escapeSafe(req.allocator, citation.source_title), lib.ui.escapeSafe(req.allocator, citation.citation_ref), lib.ui.escapeSafe(req.allocator, citation.snippet) }) catch return mer.internalError("output render failed");
    if (output.citations.len == 0) w.writeAll("<li class=\"cp-empty\">No citations were returned. This output is not presented as grounded.</li>") catch return mer.internalError("output render failed");
    w.writeAll("</ol></section>") catch return mer.internalError("output render failed");
    return lib.ui.htmlResponse(&buf);
}
