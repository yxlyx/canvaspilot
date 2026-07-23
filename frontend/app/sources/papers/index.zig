const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Papers", .description = "Review marked papers and extracted learning evidence." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Papers")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const raw_cursor = req.queryParam("cursor");
    const cursor: ?[]const u8 = if (raw_cursor) |value| if (lib.m3.safeId(value, "").len > 0) value else null else null;
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("papers render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Private learning evidence</p><h1 class=\"cp-page-title\">Papers</h1><p class=\"cp-page-sub\">Review questions and feedback extracted from marked work.</p></div></header>") catch return mer.internalError("papers render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.source_tabs, "papers", "Sources", demo) catch return mer.internalError("paper tabs failed");
    w.writeAll("<section class=\"cp-privacy-strip\"><div><p class=\"eyebrow\">Stored locally</p><h2>Your marked papers remain in this WikiBase workspace.</h2><p>Extraction creates reviewable proposals. Nothing counts as learning evidence until you confirm it.</p></div>") catch return mer.internalError("papers render failed");
    if (!demo) w.writeAll("<form method=\"post\" action=\"/api/m3\" enctype=\"multipart/form-data\" data-paper-upload data-success=\"/sources/papers\"><label class=\"cp-field\"><span>PDF, Markdown, or text · 10 MiB maximum</span><input type=\"file\" name=\"paper\" accept=\"application/pdf,text/plain,text/markdown,.md,.txt,.pdf\" required></label><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Add marked paper</button><p class=\"cp-form-status\" role=\"status\"></p></form>") catch return mer.internalError("papers render failed");
    w.writeAll("</section><section class=\"cp-paper-library\" aria-labelledby=\"paper-library-title\"><header><p class=\"eyebrow\">Review queue</p><h2 id=\"paper-library-title\">Marked papers</h2></header><div class=\"cp-paper-grid\">") catch return mer.internalError("papers render failed");
    if (demo) {
        for (lib.mock.marked_papers) |paper| w.print("<article class=\"cp-paper-card\"><div class=\"cp-paper-preview\" aria-hidden=\"true\"><span>MARKED PAPER</span><strong>{s}</strong><p>{d} extracted item(s)</p></div><div><span class=\"cp-state status-pill\">review</span><h3><a href=\"/sources/papers/{s}?mock=1\">{s}</a></h3><p>{s} extraction confidence</p></div></article>", .{ lib.ui.escapeSafe(req.allocator, paper.title), paper.evidence.len, lib.m3.safeId(paper.id, ""), lib.ui.escapeSafe(req.allocator, paper.title), lib.ui.escapeSafe(req.allocator, paper.extraction_confidence) }) catch return mer.internalError("papers render failed");
        w.writeAll("</div>") catch return mer.internalError("papers render failed");
    } else {
        const result = lib.backend.listMarkedPapers(req.allocator, lib.session.fromRequest(req).token, cursor);
        const page = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Papers", result.status);
        for (page.items) |paper| w.print("<article class=\"cp-paper-card\"><div class=\"cp-paper-preview\" aria-hidden=\"true\"><span>MARKED PAPER</span><strong>{s}</strong><p>{d} extracted question(s)</p></div><div><span class=\"cp-state status-pill\">{s}</span><h3><a href=\"/sources/papers/{s}\">{s}</a></h3><p>{s}</p></div></article>", .{ lib.ui.escapeSafe(req.allocator, paper.filename), paper.questions.len, lib.ui.escapeSafe(req.allocator, paper.extraction_status), lib.ui.escapeSafe(req.allocator, paper.id), lib.ui.escapeSafe(req.allocator, paper.filename), lib.ui.escapeSafe(req.allocator, paper.extraction_message) }) catch return mer.internalError("papers render failed");
        if (page.items.len == 0) w.writeAll("<div class=\"cp-empty\"><div><h3>No marked papers on this page</h3><p>Add a paper or return to the beginning of the review queue.</p></div></div>") catch return mer.internalError("papers render failed");
        w.writeAll("</div><nav class=\"cp-filter-row wb-m3-pagination\" aria-label=\"Marked paper pages\">") catch return mer.internalError("papers render failed");
        if (cursor != null) w.writeAll("<a class=\"filter-button\" href=\"/sources/papers\">First page</a>") catch return mer.internalError("papers render failed");
        if (page.next_cursor) |next| w.print("<a class=\"filter-button active\" href=\"/sources/papers?cursor={s}\">Next page</a>", .{lib.ui.escapeSafe(req.allocator, next)}) catch return mer.internalError("papers render failed");
        w.writeAll("</nav>") catch return mer.internalError("papers render failed");
    }
    w.writeAll("</section><script src=\"/m3.js?v=20260722\" defer></script>") catch return mer.internalError("papers render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
