const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Marked papers", .description = "Review proposed learning evidence extracted from marked papers." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Marked papers")) |response| return response;
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">Marked papers</h1><p class=\"cp-page-sub\">Privacy-sensitive evidence review. Extraction creates proposals, never confirmed knowledge.</p></div><div class=\"cp-disabled-action\"><button class=\"cp-btn cp-btn-primary\" type=\"button\" aria-disabled=\"true\" aria-describedby=\"paper-upload-note\">Upload paper</button><small id=\"paper-upload-note\">Upload is unavailable. Supported PDF or image formats will be defined with the private backend upload contract; this frontend accepts no files.</small></div></header>") catch return mer.internalError("marked papers render failed");
    lib.m3.demoBanner(req, w) catch return mer.internalError("marked papers render failed");
    w.writeAll("<section class=\"cp-card cp-privacy-note\"><h2>Privacy before upload</h2><p>Marked work may contain names, identifiers, grades, and feedback. No real upload is available in this frontend delivery; future data must be account-scoped and deletable.</p></section><section class=\"cp-list-grid\">") catch return mer.internalError("marked papers render failed");
    for (lib.mock.marked_papers) |paper| {
        const title = lib.ui.escapeSafe(req.allocator, paper.title);
        const id = lib.m3.safeId(paper.id, "");
        const confidence = lib.ui.escapeSafe(req.allocator, paper.extraction_confidence);
        w.print("<article class=\"cp-card\"><div class=\"cp-card-title\"><h2>{s}</h2><span>{s} extraction confidence</span></div>", .{ title, confidence }) catch return mer.internalError("marked papers render failed");
        if (paper.score.earned != null and paper.score.possible != null) w.print("<p>Extracted score: <strong>{d:.0}/{d:.0}</strong></p>", .{ paper.score.earned.?, paper.score.possible.? }) catch return mer.internalError("marked papers render failed") else w.writeAll("<p>Extracted score: <strong>unknown</strong></p>") catch return mer.internalError("marked papers render failed");
        w.print("<p>{d} proposed evidence items</p><a class=\"cp-btn cp-btn-ghost\" href=\"/marked-papers/{s}?mock=1\">Review proposals</a></article>", .{ paper.evidence.len, id }) catch return mer.internalError("marked papers render failed");
    }
    w.writeAll("</section>") catch return mer.internalError("marked papers render failed");
    return lib.ui.htmlResponse(&buf);
}
