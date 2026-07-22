const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Progress", .description = "Review evidence-based topic estimates and recommendations." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Progress")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<div class=\"wb-m3-page wb-m3-progress page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><h1 class=\"cp-page-title\">Knowledge progress</h1><p class=\"cp-page-sub\">Evidence-based estimates, not mastery claims. Confidence and uncertainty stay visible.</p></div></header>") catch return mer.internalError("progress render failed");
    lib.m3.demoBanner(req, w) catch return mer.internalError("progress render failed");
    const overview = lib.mock.knowledge_overview;
    const overview_confidence = lib.ui.escapeSafe(req.allocator, overview.confidence);
    const overview_recency = lib.ui.escapeSafe(req.allocator, overview.recency);
    w.writeAll("<section class=\"cp-card cp-progress-overview surface wb-m3-overview\" aria-labelledby=\"progress-overview-title\"><div class=\"cp-card-title wb-m3-card-heading\"><h2 id=\"progress-overview-title\">Workspace evidence overview</h2><span class=\"eyebrow\">aggregate estimate</span></div>") catch return mer.internalError("progress render failed");
    if (lib.m3.meterValue(overview.estimate_percent)) |value| {
        w.print("<label>Estimated knowledge across measured topics <meter min=\"0\" max=\"100\" value=\"{d}\">{d}%</meter> <strong aria-hidden=\"true\">{d}%</strong></label>", .{ value, value, value }) catch return mer.internalError("progress render failed");
    } else {
        w.writeAll("<p class=\"cp-unknown-meter\"><strong>Aggregate estimate unknown</strong> — no topic has enough evidence for a workspace percentage.</p>") catch return mer.internalError("progress render failed");
    }
    w.print("<dl class=\"cp-facts cp-overview-facts wb-m3-facts\"><div><dt>Confidence</dt><dd>{s}</dd></div><div><dt>Evidence</dt><dd>{d} signals</dd></div><div><dt>Recency</dt><dd>{s}</dd></div><div><dt>Coverage</dt><dd>{d} known · {d} unknown</dd></div></dl><p class=\"cp-muted-copy\">The aggregate includes only topics with enough evidence. Unknown topics stay unknown and are never counted as 0%.</p></section>", .{ overview_confidence, overview.evidence_count, overview_recency, overview.known_topic_count, overview.unknown_topic_count }) catch return mer.internalError("progress render failed");
    w.writeAll("<section class=\"cp-meter-grid wb-m3-meter-grid\">") catch return mer.internalError("progress render failed");
    for (lib.mock.knowledge_meters) |meter| {
        const topic = lib.ui.escapeSafe(req.allocator, meter.topic);
        const confidence = lib.ui.escapeSafe(req.allocator, meter.confidence);
        const recency = lib.ui.escapeSafe(req.allocator, meter.recency);
        const trend = lib.ui.escapeSafe(req.allocator, meter.trend);
        w.print("<article class=\"cp-card cp-meter-card surface wb-m3-meter-card\"><div class=\"cp-card-title wb-m3-card-heading\"><h2>{s}</h2><span>{s} confidence</span></div>", .{ topic, confidence }) catch return mer.internalError("progress render failed");
        if (lib.m3.meterValue(meter.estimate_percent)) |value| {
            w.print("<label>Estimated knowledge <meter min=\"0\" max=\"100\" value=\"{d}\">{d}%</meter> <strong aria-hidden=\"true\">{d}%</strong></label>", .{ value, value, value }) catch return mer.internalError("progress render failed");
        } else {
            w.writeAll("<p class=\"cp-unknown-meter\"><strong>Estimate unknown</strong> — not enough evidence to calculate a percentage.</p>") catch return mer.internalError("progress render failed");
        }
        w.print("<dl class=\"cp-facts wb-m3-facts\"><div><dt>Evidence</dt><dd>{d} signals</dd></div><div><dt>Recency</dt><dd>{s}</dd></div><div><dt>Trend</dt><dd>{s}</dd></div></dl><h3>Signals</h3><ul class=\"cp-plain-list wb-m3-signals\">", .{ meter.evidence_count, recency, trend }) catch return mer.internalError("progress render failed");
        for (meter.signals) |signal| {
            const label = lib.ui.escapeSafe(req.allocator, signal.label);
            const evidence = lib.ui.escapeSafe(req.allocator, signal.evidence);
            w.print("<li><strong>{s}</strong>: {s}</li>", .{ label, evidence }) catch return mer.internalError("progress render failed");
        }
        w.writeAll("</ul></article>") catch return mer.internalError("progress render failed");
    }
    w.writeAll("</section><section class=\"cp-card surface wb-m3-recommendations\"><div class=\"cp-card-title wb-m3-card-heading\"><h2>Recommendations</h2><span class=\"eyebrow\">evidence-led</span></div>") catch return mer.internalError("progress render failed");
    for (lib.mock.recommendations) |recommendation| {
        const title = lib.ui.escapeSafe(req.allocator, recommendation.title);
        const why = lib.ui.escapeSafe(req.allocator, recommendation.why);
        const evidence = lib.ui.escapeSafe(req.allocator, recommendation.evidence);
        const action = lib.ui.escapeSafe(req.allocator, recommendation.next_action);
        w.print("<article class=\"cp-recommendation wb-m3-recommendation\"><h3>{s}</h3><p><strong>Why:</strong> {s}</p><p><strong>Evidence:</strong> {s}</p><p><strong>Next action:</strong> {s}</p><div class=\"cp-action-row wb-m3-actions\">", .{ title, why, evidence, action }) catch return mer.internalError("progress render failed");
        for (recommendation.actions) |recommendation_action| {
            const action_label = lib.ui.escapeSafe(req.allocator, recommendation_action.label);
            const internal_href = lib.m3.safeInternalHref(recommendation_action.href, "/progress");
            const demo_href = lib.m3.demoHref(req.allocator, req, internal_href) catch return mer.internalError("progress render failed");
            const action_href = lib.ui.escapeSafe(req.allocator, demo_href);
            w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"{s}\">{s}</a>", .{ action_href, action_label }) catch return mer.internalError("progress render failed");
        }
        w.writeAll("</div></article>") catch return mer.internalError("progress render failed");
    }
    w.writeAll("</section></div>") catch return mer.internalError("progress render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderLive(req: mer.Request) mer.Response {
    const result = lib.backend.topicMeters(req.allocator, lib.session.fromRequest(req).token);
    const meters = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Knowledge meter", result.status);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<div class=\"wb-m3-page wb-m3-progress page-grid\"><header class=\"cp-page-header wb-m3-header\"><div><h1 class=\"cp-page-title\">Knowledge meter</h1><p class=\"cp-page-sub\">Backend-measured topic evidence. Unknown values remain unknown—no live percentage is invented.</p></div></header><section class=\"cp-meter-grid wb-m3-meter-grid\">") catch return mer.internalError("meter render failed");
    for (meters) |meter| {
        w.print("<article class=\"cp-card cp-meter-card surface wb-m3-meter-card\"><div class=\"cp-card-title wb-m3-card-heading\"><h2>{s}</h2><span class=\"cp-state cp-state-{s} status-pill wb-m3-state\">{s}</span></div>", .{ lib.ui.escapeSafe(req.allocator, meter.topic), lib.ui.escapeSafe(req.allocator, meter.state), lib.ui.escapeSafe(req.allocator, meter.state) }) catch return mer.internalError("meter render failed");
        if (lib.m3.meterPercent(meter.estimated_completion)) |value| w.print("<label>Measured completion <meter min=\"0\" max=\"100\" value=\"{d}\">{d}%</meter> <strong>{d}%</strong></label>", .{ value, value, value }) catch return mer.internalError("meter render failed") else w.writeAll("<p class=\"cp-unknown-meter\"><strong>Estimate uncertain</strong> — insufficient evidence for a percentage.</p>") catch return mer.internalError("meter render failed");
        w.print("<dl class=\"cp-facts wb-m3-facts\"><div><dt>Evidence</dt><dd>{d} observations</dd></div><div><dt>Confidence</dt><dd>{d:.0}%</dd></div><div><dt>Freshness</dt><dd>{s}</dd></div></dl><h3>Contributing signals</h3><ul class=\"cp-plain-list wb-m3-signals\">", .{ meter.evidence_count, meter.evidence_confidence * 100, if (meter.stale) "Stale" else "Current" }) catch return mer.internalError("meter render failed");
        for (meter.signals) |signal| w.print("<li><strong>{s}</strong>: {d} evidence item(s){s}</li>", .{ lib.ui.escapeSafe(req.allocator, signal.name), signal.evidence_count, if (signal.value == null) " · value uncertain" else "" }) catch return mer.internalError("meter render failed");
        w.print("</ul><aside class=\"cp-recommendation wb-m3-recommendation\"><h3>Recommended next step</h3><p>{s}</p><div class=\"cp-action-row wb-m3-actions\"><a class=\"cp-btn cp-btn-ghost\" href=\"/wiki\">Review notes</a><a class=\"cp-btn cp-btn-ghost\" href=\"/flashcards\">Practise cards</a><a class=\"cp-btn cp-btn-ghost\" href=\"/marked-papers\">Review evidence</a></div></aside></article>", .{lib.ui.escapeSafe(req.allocator, meter.recommendation)}) catch return mer.internalError("meter render failed");
    }
    if (meters.len == 0) w.writeAll("<div class=\"cp-empty wb-m3-empty\"><h2>No measured topics</h2><p>Add reviewed evidence before expecting knowledge estimates or recommendations.</p></div>") catch return mer.internalError("meter render failed");
    w.writeAll("</section></div>") catch return mer.internalError("meter render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
