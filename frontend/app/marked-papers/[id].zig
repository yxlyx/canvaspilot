const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Marked paper evidence", .description = "Review unconfirmed evidence proposals from a marked paper." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Marked paper evidence")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
    const raw_id = req.param("id") orelse "";
    const id = lib.m3.safeId(raw_id, "");
    const paper = findPaper(id) orelse return missing(req, raw_id);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const title = lib.ui.escapeSafe(req.allocator, paper.title);
    const privacy = lib.ui.escapeSafe(req.allocator, paper.privacy_note);
    const paper_confidence = lib.ui.escapeSafe(req.allocator, paper.extraction_confidence);
    w.print("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Extraction confidence: {s}. These are proposals, not confirmations.</p></div><a class=\"cp-btn cp-btn-ghost\" href=\"/marked-papers?mock=1\">All papers</a></header>", .{ title, paper_confidence }) catch return mer.internalError("paper render failed");
    lib.m3.demoBanner(req, w) catch return mer.internalError("paper render failed");
    w.print("<section class=\"cp-card cp-privacy-note\"><h2>Privacy</h2><p>{s}</p></section><section class=\"cp-list-grid\" aria-labelledby=\"evidence-proposals-title\"><h2 class=\"cp-list-heading\" id=\"evidence-proposals-title\">Evidence proposals</h2>", .{privacy}) catch return mer.internalError("paper render failed");
    if (paper.evidence.len == 0) w.writeAll("<div class=\"cp-empty\">No evidence could be extracted with useful confidence.</div>") catch return mer.internalError("paper render failed");
    for (paper.evidence) |evidence| {
        const question = lib.ui.escapeSafe(req.allocator, evidence.question);
        const feedback = lib.ui.escapeSafe(req.allocator, evidence.feedback);
        const proposal = lib.ui.escapeSafe(req.allocator, evidence.proposal);
        const confidence = lib.ui.escapeSafe(req.allocator, evidence.extraction_confidence);
        const topic = lib.ui.escapeSafe(req.allocator, evidence.topic);
        const evidence_id = lib.m3.safeId(evidence.id, "evidence");
        w.print("<article class=\"cp-card\"><div class=\"cp-card-title\"><h3>{s}</h3><span>{s} confidence</span></div><p><strong>Topic:</strong> {s}</p>", .{ question, confidence, topic }) catch return mer.internalError("paper render failed");
        if (evidence.score.earned != null and evidence.score.possible != null) w.print("<p><strong>Score:</strong> {d:.0}/{d:.0}</p>", .{ evidence.score.earned.?, evidence.score.possible.? }) catch return mer.internalError("paper render failed") else w.writeAll("<p><strong>Score:</strong> unknown</p>") catch return mer.internalError("paper render failed");
        w.print("<p>{s}</p><p class=\"cp-proposal\"><strong>Unconfirmed proposal:</strong> {s}</p><div class=\"cp-action-row\"><button class=\"cp-btn cp-btn-primary\" type=\"button\" aria-disabled=\"true\" aria-describedby=\"evidence-note-{s}\">Accept</button><button class=\"cp-btn cp-btn-ghost\" type=\"button\" aria-disabled=\"true\" aria-describedby=\"evidence-note-{s}\">Edit</button><button class=\"cp-btn cp-btn-danger\" type=\"button\" aria-disabled=\"true\" aria-describedby=\"evidence-note-{s}\">Reject</button></div><small id=\"evidence-note-{s}\">Evidence decisions are unavailable until a backend mutation contract exists.</small></article>", .{ feedback, proposal, evidence_id, evidence_id, evidence_id, evidence_id }) catch return mer.internalError("paper render failed");
    }
    w.writeAll("</section>") catch return mer.internalError("paper render failed");
    return lib.ui.htmlResponse(&buf);
}

fn renderLive(req: mer.Request) mer.Response {
    const raw_id = req.param("id") orelse return mer.notFound();
    const id = lib.m3.safeId(raw_id, "");
    if (id.len == 0) return mer.notFound();
    const result = lib.backend.getMarkedPaper(req.allocator, lib.session.fromRequest(req).token, id);
    if (result.status == 404) return mer.notFound();
    const paper = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Marked paper", result.status);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.print("<header class=\"cp-page-header\"><div><a href=\"/marked-papers\">← All papers</a><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Extraction {s}: {s}</p></div><form method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"Permanently delete this private paper and all extracted questions?\" data-success=\"/marked-papers\"><input type=\"hidden\" name=\"action\" value=\"paper.delete\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Delete paper</button><span class=\"cp-form-status\" role=\"status\"></span></form></header><section class=\"cp-card cp-privacy-note\"><h2>Private evidence review</h2><p>Check extracted text, marks, topic and confidence before marking an item reviewed. Unknown marks stay blank.</p></section><section class=\"cp-list-grid\">", .{ lib.ui.escapeSafe(req.allocator, paper.filename), lib.ui.escapeSafe(req.allocator, paper.extraction_status), lib.ui.escapeSafe(req.allocator, paper.extraction_message), id }) catch return mer.internalError("paper render failed");
    for (paper.questions) |question| {
        w.print("<article class=\"cp-card\"><form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"paper.updateQuestion\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><input type=\"hidden\" name=\"child_id\" value=\"{s}\"><h2>Question {d}</h2><label class=\"cp-field\"><span>Question text</span><textarea name=\"question_text\" required maxlength=\"20000\">{s}</textarea></label><div class=\"cp-selector-grid\"><label class=\"cp-field\"><span>Awarded marks</span><input type=\"number\" step=\"0.5\" min=\"0\" name=\"awarded_marks\" value=\"{s}\"></label><label class=\"cp-field\"><span>Available marks</span><input type=\"number\" step=\"0.5\" min=\"0.5\" name=\"available_marks\" value=\"{s}\"></label><label class=\"cp-field\"><span>Topic</span><input name=\"topic_tag\" maxlength=\"100\" required value=\"{s}\"></label><label class=\"cp-field\"><span>Confidence (0–1)</span><input type=\"number\" step=\"0.01\" min=\"0\" max=\"1\" name=\"confidence\" value=\"{d:.2}\"></label></div><label class=\"cp-field\"><span>Feedback</span><textarea name=\"feedback\" maxlength=\"10000\">{s}</textarea></label><label><input type=\"checkbox\" name=\"reviewed\"{s}> Reviewed and confirmed</label><div class=\"cp-action-row\"><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save review</button></div></form><div class=\"cp-action-row\"><form method=\"post\" action=\"/api/m3\" data-m3-form data-confirm=\"Delete this question?\" data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"paper.deleteQuestion\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><input type=\"hidden\" name=\"child_id\" value=\"{s}\"><button class=\"cp-btn cp-btn-danger\" type=\"submit\">Delete question</button></form></div><p class=\"cp-form-status\" role=\"status\"></p></article>", .{ id, lib.ui.escapeSafe(req.allocator, question.id), question.question_number, lib.ui.escapeSafe(req.allocator, question.question_text), number(req, question.awarded_marks), number(req, question.available_marks), lib.ui.escapeSafe(req.allocator, question.topic_tag), question.confidence, lib.ui.escapeSafe(req.allocator, question.feedback), if (question.reviewed) " checked" else "", id, lib.ui.escapeSafe(req.allocator, question.id) }) catch return mer.internalError("paper render failed");
    }
    w.print("</section><section class=\"cp-card\"><h2>Add question manually</h2><form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"\"><input type=\"hidden\" name=\"action\" value=\"paper.addQuestion\"><input type=\"hidden\" name=\"id\" value=\"{s}\"><div class=\"cp-selector-grid\"><label class=\"cp-field\"><span>Question number</span><input type=\"number\" min=\"1\" name=\"question_number\" required></label><label class=\"cp-field\"><span>Topic</span><input name=\"topic_tag\" value=\"general\" required></label><label class=\"cp-field\"><span>Confidence (0–1)</span><input type=\"number\" step=\"0.01\" min=\"0\" max=\"1\" name=\"confidence\" value=\"0.5\" required></label></div><label class=\"cp-field\"><span>Question text</span><textarea name=\"question_text\" required></textarea></label><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Add question</button><p class=\"cp-form-status\" role=\"status\"></p></form></section><script src=\"/m3.js\" defer></script>", .{id}) catch return mer.internalError("paper render failed");
    return lib.ui.htmlResponse(&buf);
}
fn number(req: mer.Request, value: ?f64) []const u8 {
    return if (value) |v| std.fmt.allocPrint(req.allocator, "{d}", .{v}) catch "" else "";
}

fn findPaper(id: []const u8) ?lib.types.MarkedPaper {
    for (lib.mock.marked_papers) |paper| if (std.mem.eql(u8, paper.id, id)) return paper;
    return null;
}

fn missing(req: mer.Request, raw_id: []const u8) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    lib.m3.demoMarker(req, &buf.writer) catch return mer.internalError("paper render failed");
    const safe = lib.ui.escapeSafe(req.allocator, raw_id);
    buf.writer.print("<section class=\"cp-card\"><h1>Marked paper not found</h1><p>No synthetic paper matches <strong>{s}</strong>.</p><a href=\"/marked-papers?mock=1\">Return to marked papers</a></section>", .{safe}) catch return mer.internalError("paper render failed");
    return .{ .status = .not_found, .content_type = .html, .body = buf.written() };
}
