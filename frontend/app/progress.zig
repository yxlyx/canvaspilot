const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Progress", .description = "Review evidence-based topic estimates and recommendations." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Progress")) |response| return response;
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">Knowledge progress</h1><p class=\"cp-page-sub\">Evidence-based estimates, not mastery claims. Confidence and uncertainty stay visible.</p></div></header>") catch return mer.internalError("progress render failed");
    lib.m3.demoBanner(w) catch return mer.internalError("progress render failed");
    w.writeAll("<section class=\"cp-meter-grid\">") catch return mer.internalError("progress render failed");
    for (lib.mock.knowledge_meters) |meter| {
        const topic = lib.ui.escape(req.allocator, meter.topic) catch meter.topic;
        const confidence = lib.ui.escape(req.allocator, meter.confidence) catch meter.confidence;
        const recency = lib.ui.escape(req.allocator, meter.recency) catch meter.recency;
        const trend = lib.ui.escape(req.allocator, meter.trend) catch meter.trend;
        w.print("<article class=\"cp-card cp-meter-card\"><div class=\"cp-card-title\"><h2>{s}</h2><span>{s} confidence</span></div>", .{ topic, confidence }) catch return mer.internalError("progress render failed");
        if (lib.m3.meterValue(meter.estimate_percent)) |value| {
            w.print("<label>Estimated knowledge <meter min=\"0\" max=\"100\" value=\"{d}\">{d}%</meter> <strong>{d}%</strong></label>", .{ value, value, value }) catch return mer.internalError("progress render failed");
        } else {
            w.writeAll("<p class=\"cp-unknown-meter\"><strong>Estimate unknown</strong> — not enough evidence to calculate a percentage.</p>") catch return mer.internalError("progress render failed");
        }
        w.print("<dl class=\"cp-facts\"><div><dt>Evidence</dt><dd>{d} signals</dd></div><div><dt>Recency</dt><dd>{s}</dd></div><div><dt>Trend</dt><dd>{s}</dd></div></dl><h3>Signals</h3><ul class=\"cp-plain-list\">", .{ meter.evidence_count, recency, trend }) catch return mer.internalError("progress render failed");
        for (meter.signals) |signal| {
            const label = lib.ui.escape(req.allocator, signal.label) catch signal.label;
            const evidence = lib.ui.escape(req.allocator, signal.evidence) catch signal.evidence;
            w.print("<li><strong>{s}</strong>: {s}</li>", .{ label, evidence }) catch return mer.internalError("progress render failed");
        }
        w.writeAll("</ul></article>") catch return mer.internalError("progress render failed");
    }
    w.writeAll("</section><section class=\"cp-card\"><div class=\"cp-card-title\"><h2>Recommendations</h2><span>evidence-led</span></div>") catch return mer.internalError("progress render failed");
    for (lib.mock.recommendations) |recommendation| {
        const title = lib.ui.escape(req.allocator, recommendation.title) catch recommendation.title;
        const why = lib.ui.escape(req.allocator, recommendation.why) catch recommendation.why;
        const evidence = lib.ui.escape(req.allocator, recommendation.evidence) catch recommendation.evidence;
        const action = lib.ui.escape(req.allocator, recommendation.next_action) catch recommendation.next_action;
        w.print("<article class=\"cp-recommendation\"><h3>{s}</h3><p><strong>Why:</strong> {s}</p><p><strong>Evidence:</strong> {s}</p><p><strong>Next action:</strong> {s}</p></article>", .{ title, why, evidence, action }) catch return mer.internalError("progress render failed");
    }
    w.writeAll("</section>") catch return mer.internalError("progress render failed");
    return lib.ui.htmlResponse(&buf);
}
