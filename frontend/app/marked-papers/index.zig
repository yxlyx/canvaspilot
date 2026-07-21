const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Marked papers", .description = "Review proposed learning evidence extracted from marked papers." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Marked papers")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
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

fn renderLive(req: mer.Request) mer.Response {
    const raw_cursor = req.queryParam("cursor");
    const cursor: ?[]const u8 = if (raw_cursor) |value| if (lib.m3.safeId(value, "").len > 0) value else null else null;
    const result = lib.backend.listMarkedPapers(req.allocator, lib.session.fromRequest(req).token, cursor);
    const page = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Marked papers", result.status);
    const papers = page.items;
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">Private marked papers</h1><p class=\"cp-page-sub\">Account-private extraction and manual evidence review.</p></div></header><section class=\"cp-card cp-privacy-note\"><h2>Private upload</h2><p>Supported formats are PDF, plain text, and Markdown (maximum 10 MiB). Files are sent only in the authenticated request and are never stored in browser storage.</p><form method=\"post\" action=\"/api/m3\" data-paper-upload data-success=\"/marked-papers\"><label class=\"cp-field\"><span>Marked paper file</span><input type=\"file\" name=\"paper\" accept=\"application/pdf,text/plain,text/markdown,.md,.txt,.pdf\" required></label><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Upload privately</button><p class=\"cp-form-status\" role=\"status\" aria-live=\"polite\"></p></form></section><section class=\"cp-list-grid\">") catch return mer.internalError("papers render failed");
    for (papers) |paper| w.print("<article class=\"cp-card\"><div class=\"cp-card-title\"><h2>{s}</h2><span class=\"cp-state\">{s}</span></div><p>{s}</p><p>{d} extracted question(s)</p><a class=\"cp-btn cp-btn-ghost\" href=\"/marked-papers/{s}\">Review paper</a></article>", .{ lib.ui.escapeSafe(req.allocator, paper.filename), lib.ui.escapeSafe(req.allocator, paper.extraction_status), lib.ui.escapeSafe(req.allocator, paper.extraction_message), paper.questions.len, lib.ui.escapeSafe(req.allocator, paper.id) }) catch return mer.internalError("papers render failed");
    if (papers.len == 0) w.writeAll("<div class=\"cp-empty\"><h2>No marked papers</h2><p>Upload a supported file to begin private review.</p></div>") catch return mer.internalError("papers render failed");
    w.writeAll("</section><nav class=\"cp-filter-row\" aria-label=\"Marked paper pages\">") catch return mer.internalError("papers render failed");
    if (page.next_cursor) |next| w.print("<a href=\"/marked-papers?cursor={s}\">Next</a>", .{lib.ui.escapeSafe(req.allocator, next)}) catch return mer.internalError("papers render failed");
    w.writeAll("</nav><script src=\"/m3.js?v=20260721\" defer></script>") catch return mer.internalError("papers render failed");
    return lib.ui.htmlResponse(&buf);
}
