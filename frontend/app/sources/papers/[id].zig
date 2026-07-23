const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Paper review", .description = "Review extracted marked-paper questions." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Paper review")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const raw_id = req.param("id") orelse return renderMissing(req, "", demo);
    const id = lib.m3.safeId(raw_id, "");
    if (id.len == 0) return renderMissing(req, raw_id, demo);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("paper render failed");
    if (demo) {
        var found: ?lib.types.MarkedPaper = null;
        for (lib.mock.marked_papers) |paper| if (std.mem.eql(u8, paper.id, id)) {
            found = paper;
            break;
        };
        const paper = found orelse return renderMissing(req, id, true);
        w.print("<header class=\"cp-page-header\"><div><a class=\"article-breadcrumb\" href=\"/sources/papers?mock=1\">← Papers</a><p class=\"cp-page-kicker\">Review proposed evidence</p><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">{s} extraction confidence · nothing is confirmed automatically</p></div></header><article class=\"cp-paper-reader\"><aside class=\"cp-paper-sheet\"><span>MARKED PAPER</span><h2>{s}</h2><p>{s}</p></aside><section class=\"cp-question-ledger\"><header><p class=\"eyebrow\">Extracted questions</p><h2>Review each proposal</h2></header>", .{ lib.ui.escapeSafe(req.allocator, paper.title), lib.ui.escapeSafe(req.allocator, paper.extraction_confidence), lib.ui.escapeSafe(req.allocator, paper.title), lib.ui.escapeSafe(req.allocator, paper.privacy_note) }) catch return mer.internalError("paper render failed");
        for (paper.evidence) |evidence| w.print("<article><div><span class=\"cp-state status-pill\">proposal</span><h3>{s}</h3><p><strong>{s}</strong> · {s}</p><p>{s}</p></div><p>{s}</p></article>", .{ lib.ui.escapeSafe(req.allocator, evidence.question), lib.ui.escapeSafe(req.allocator, evidence.topic), lib.ui.escapeSafe(req.allocator, evidence.extraction_confidence), lib.ui.escapeSafe(req.allocator, evidence.feedback), lib.ui.escapeSafe(req.allocator, evidence.proposal) }) catch return mer.internalError("paper render failed");
    } else {
        const result = lib.backend.getMarkedPaper(req.allocator, lib.session.fromRequest(req).token, id);
        if (result.status == 404) return renderMissing(req, id, false);
        const paper = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Paper review", result.status);
        w.print("<header class=\"cp-page-header\"><div><a class=\"article-breadcrumb\" href=\"/sources/papers\">← Papers</a><p class=\"cp-page-kicker\">{s}</p><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">{s}</p></div><form method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"Permanently delete this paper?\" data-success=\"/sources/papers\"><input type=\"hidden\" name=\"action\" value=\"paper.delete\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Delete paper</button></form></header><article class=\"cp-paper-reader\"><aside class=\"cp-paper-sheet\"><span>MARKED PAPER</span><h2>{s}</h2><p>{d} extracted questions</p></aside><section class=\"cp-question-ledger\"><header><p class=\"eyebrow\">Extracted questions</p><h2>Review each item</h2></header>", .{ lib.ui.escapeSafe(req.allocator, paper.extraction_status), lib.ui.escapeSafe(req.allocator, paper.filename), lib.ui.escapeSafe(req.allocator, paper.extraction_message), id, lib.ui.escapeSafe(req.allocator, paper.filename), paper.questions.len }) catch return mer.internalError("paper render failed");
        for (paper.questions) |question| renderQuestion(req, w, id, question) catch return mer.internalError("paper render failed");
        w.print("<article class=\"cp-manual-question\"><form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"paper.addQuestion\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><h3>Add a question manually</h3><label class=\"cp-field\"><span>Question number</span><input type=\"number\" min=\"1\" name=\"question_number\" required></label><label class=\"cp-field\"><span>Question</span><textarea name=\"question_text\" required></textarea></label><label class=\"cp-field\"><span>Topic</span><input name=\"topic_tag\" value=\"general\" required></label><input type=\"hidden\" name=\"confidence\" value=\"0.5\"><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Add question</button><p class=\"cp-form-status\" role=\"status\"></p></form></article>", .{id}) catch return mer.internalError("paper render failed");
    }
    w.writeAll("</section></article><script src=\"/m3.js?v=20260722\" defer></script>") catch return mer.internalError("paper render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderMissing(req: mer.Request, id: []const u8, demo: bool) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("paper state render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Private learning evidence</p><h1 class=\"cp-page-title\">Paper not found</h1><p class=\"cp-page-sub\">This marked paper does not exist or is no longer available.</p></div></header>") catch return mer.internalError("paper state render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.source_tabs, "papers", "Sources", demo) catch return mer.internalError("paper state tabs failed");
    const href = lib.m3.demoHrefFor(req.allocator, demo, "/sources/papers") catch return mer.internalError("paper state link failed");
    w.print("<section class=\"cp-boundary\" role=\"status\"><p class=\"eyebrow\">No paper here</p><h2>Nothing was opened or inferred.</h2><p>No marked-paper record matches <strong>{s}</strong>.</p><a class=\"cp-btn cp-btn-ghost\" href=\"{s}\">Return to Papers</a></section>", .{ lib.ui.escapeSafe(req.allocator, id), href }) catch return mer.internalError("paper state render failed");
    var response = lib.ui.htmlResponse(&buf);
    response.status = .not_found;
    return lib.m3.privateForSession(req, response);
}

fn renderQuestion(req: mer.Request, w: *std.Io.Writer, paper_id: []const u8, question: lib.types.MarkedPaperQuestionResponse) !void {
    try w.print("<article><form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"paper.updateQuestion\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><input type=\"hidden\" name=\"child_id\" value=\"{s}\"><div><span class=\"cp-state status-pill\">{s}</span><h3>Question {d}</h3></div><label class=\"cp-field\"><span>Question text</span><textarea name=\"question_text\" required>{s}</textarea></label><div class=\"cp-settings-inline\"><label class=\"cp-field\"><span>Awarded marks</span><input type=\"number\" min=\"0\" step=\"0.5\" name=\"awarded_marks\" value=\"{s}\"></label><label class=\"cp-field\"><span>Available marks</span><input type=\"number\" min=\"0.5\" step=\"0.5\" name=\"available_marks\" value=\"{s}\"></label><label class=\"cp-field\"><span>Topic</span><input name=\"topic_tag\" value=\"{s}\" required></label><label class=\"cp-field\"><span>Confidence</span><input type=\"number\" min=\"0\" max=\"1\" step=\"0.01\" name=\"confidence\" value=\"{d:.2}\"></label></div><label class=\"cp-field\"><span>Feedback</span><textarea name=\"feedback\">{s}</textarea></label><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"reviewed\"{s}><span>Reviewed and confirmed</span></label><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save review</button><p class=\"cp-form-status\" role=\"status\"></p></form></article>", .{ paper_id, lib.ui.escapeSafe(req.allocator, question.id), if (question.reviewed) "reviewed" else "proposal", question.question_number, lib.ui.escapeSafe(req.allocator, question.question_text), number(req, question.awarded_marks), number(req, question.available_marks), lib.ui.escapeSafe(req.allocator, question.topic_tag), question.confidence, lib.ui.escapeSafe(req.allocator, question.feedback), if (question.reviewed) " checked" else "" });
}

fn number(req: mer.Request, value: ?f64) []const u8 {
    return if (value) |v| std.fmt.allocPrint(req.allocator, "{d}", .{v}) catch "" else "";
}
