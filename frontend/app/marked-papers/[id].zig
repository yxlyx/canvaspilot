const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Marked paper evidence", .description = "Review unconfirmed evidence proposals from a marked paper." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Marked paper evidence")) |response| return response;
    const raw_id = req.param("id") orelse "";
    const id = lib.m3.safeId(raw_id, "");
    const paper = findPaper(id) orelse return missing(req, raw_id);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const title = lib.ui.escape(req.allocator, paper.title) catch paper.title;
    const privacy = lib.ui.escape(req.allocator, paper.privacy_note) catch paper.privacy_note;
    const paper_confidence = lib.ui.escape(req.allocator, paper.extraction_confidence) catch paper.extraction_confidence;
    w.print("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Extraction confidence: {s}. These are proposals, not confirmations.</p></div><a class=\"cp-btn cp-btn-ghost\" href=\"/marked-papers?mock=1\">All papers</a></header>", .{ title, paper_confidence }) catch return mer.internalError("paper render failed");
    lib.m3.demoBanner(w) catch return mer.internalError("paper render failed");
    w.print("<section class=\"cp-card cp-privacy-note\"><h2>Privacy</h2><p>{s}</p></section><section class=\"cp-list-grid\">", .{privacy}) catch return mer.internalError("paper render failed");
    if (paper.evidence.len == 0) w.writeAll("<div class=\"cp-empty\">No evidence could be extracted with useful confidence.</div>") catch return mer.internalError("paper render failed");
    for (paper.evidence) |evidence| {
        const question = lib.ui.escape(req.allocator, evidence.question) catch evidence.question;
        const feedback = lib.ui.escape(req.allocator, evidence.feedback) catch evidence.feedback;
        const proposal = lib.ui.escape(req.allocator, evidence.proposal) catch evidence.proposal;
        const confidence = lib.ui.escape(req.allocator, evidence.extraction_confidence) catch evidence.extraction_confidence;
        const topic = lib.ui.escape(req.allocator, evidence.topic) catch evidence.topic;
        w.print("<article class=\"cp-card\"><div class=\"cp-card-title\"><h2>{s}</h2><span>{s} confidence</span></div><p><strong>Topic:</strong> {s}</p>", .{ question, confidence, topic }) catch return mer.internalError("paper render failed");
        if (evidence.score.earned != null and evidence.score.possible != null) w.print("<p><strong>Score:</strong> {d:.0}/{d:.0}</p>", .{ evidence.score.earned.?, evidence.score.possible.? }) catch return mer.internalError("paper render failed") else w.writeAll("<p><strong>Score:</strong> unknown</p>") catch return mer.internalError("paper render failed");
        w.print("<p>{s}</p><p class=\"cp-proposal\"><strong>Unconfirmed proposal:</strong> {s}</p><div class=\"cp-action-row\"><button class=\"cp-btn cp-btn-primary\" disabled>Accept</button><button class=\"cp-btn cp-btn-ghost\" disabled>Edit</button><button class=\"cp-btn cp-btn-danger\" disabled>Reject</button></div><small>Evidence mutation requires a backend contract.</small></article>", .{ feedback, proposal }) catch return mer.internalError("paper render failed");
    }
    w.writeAll("</section>") catch return mer.internalError("paper render failed");
    return lib.ui.htmlResponse(&buf);
}

fn findPaper(id: []const u8) ?lib.types.MarkedPaper {
    for (lib.mock.marked_papers) |paper| if (std.mem.eql(u8, paper.id, id)) return paper;
    return null;
}

fn missing(req: mer.Request, raw_id: []const u8) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const safe = lib.ui.escape(req.allocator, raw_id) catch "unknown";
    buf.writer.print("<section class=\"cp-card\"><h1>Marked paper not found</h1><p>No synthetic paper matches <strong>{s}</strong>.</p><a href=\"/marked-papers?mock=1\">Return to marked papers</a></section>", .{safe}) catch return mer.internalError("paper render failed");
    return .{ .status = .not_found, .content_type = .html, .body = buf.written() };
}
