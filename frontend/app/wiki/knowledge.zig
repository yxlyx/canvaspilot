const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Knowledge", .description = "Review evidence-backed topic estimates." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Knowledge")) |response| return response;
    const use_mock = lib.m3.isExplicitDemo(req);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("knowledge render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">") catch return mer.internalError("knowledge render failed");
    w.writeAll(if (use_mock) "Synthetic demo · learning evidence" else "Learning evidence") catch return mer.internalError("knowledge render failed");
    w.writeAll("</p><h1 class=\"cp-page-title\">Knowledge</h1><p class=\"cp-page-sub\">Evidence-based estimates keep uncertainty, recency, and supporting signals visible.</p></div></header>") catch return mer.internalError("knowledge render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.wiki_tabs, "knowledge", "Wiki", use_mock) catch return mer.internalError("knowledge tabs failed");
    if (use_mock) {
        const overview = lib.mock.knowledge_overview;
        w.writeAll("<section class=\"wb-m3-overview cp-knowledge-summary\"><div><p class=\"eyebrow\">Measured topics only</p><h2>What the evidence currently supports.</h2><p>Unknown topics remain unknown instead of being counted as zero.</p></div>") catch return mer.internalError("knowledge render failed");
        if (lib.m3.meterValue(overview.estimate_percent)) |value| {
            w.print("<div class=\"cp-knowledge-ring\"><strong>{d}%</strong><span>estimated</span></div>", .{value}) catch return mer.internalError("knowledge render failed");
        } else w.writeAll("<div class=\"cp-knowledge-ring cp-knowledge-ring-unknown\"><strong>—</strong><span>not enough evidence</span></div>") catch return mer.internalError("knowledge render failed");
        w.writeAll("</section><section class=\"cp-settings-ledger cp-knowledge-ledger\" aria-labelledby=\"topic-ledger\"><header><div><p class=\"eyebrow\">Topic ledger</p><h2 id=\"topic-ledger\">Measured knowledge</h2></div></header>") catch return mer.internalError("knowledge render failed");
        for (lib.mock.knowledge_meters) |meter| renderMockMeter(req, w, meter) catch return mer.internalError("knowledge render failed");
        w.writeAll("</section>") catch return mer.internalError("knowledge render failed");
    } else {
        const result = lib.backend.topicMeters(req.allocator, lib.session.fromRequest(req).token);
        const meters = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Knowledge", result.status);
        w.writeAll("<section class=\"wb-m3-overview cp-knowledge-summary\"><div><p class=\"eyebrow\">Current evidence</p><h2>What your workspace can support.</h2><p>Completion appears only where there is enough recent evidence.</p></div><div class=\"cp-knowledge-ring cp-knowledge-ring-unknown\"><strong>—</strong><span>topic-level evidence</span></div></section><section class=\"cp-settings-ledger cp-knowledge-ledger\" aria-labelledby=\"topic-ledger\"><header><div><p class=\"eyebrow\">Topic ledger</p><h2 id=\"topic-ledger\">Measured knowledge</h2></div></header>") catch return mer.internalError("knowledge render failed");
        for (meters) |meter| renderLiveMeter(req, w, meter) catch return mer.internalError("knowledge render failed");
        if (meters.len == 0) w.writeAll("<div class=\"cp-empty\"><div><h3>No measured topics yet</h3><p>Review flashcards or marked work to create learning evidence.</p></div></div>") catch return mer.internalError("knowledge render failed");
        w.writeAll("</section>") catch return mer.internalError("knowledge render failed");
    }
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderMockMeter(req: mer.Request, w: *std.Io.Writer, meter: lib.types.KnowledgeMeter) !void {
    try w.print("<article class=\"wb-m3-meter-card\"><div><p class=\"eyebrow\">{s} confidence</p><h3>{s}</h3><p>{d} evidence signals · {s}</p></div><div>", .{ lib.ui.escapeSafe(req.allocator, meter.confidence), lib.ui.escapeSafe(req.allocator, meter.topic), meter.evidence_count, lib.ui.escapeSafe(req.allocator, meter.recency) });
    if (lib.m3.meterValue(meter.estimate_percent)) |value| try w.print("<label>Estimated completion <meter min=\"0\" max=\"100\" value=\"{d}\">{d}%</meter><strong>{d}%</strong></label>", .{ value, value, value }) else try w.writeAll("<p class=\"cp-unknown-meter\"><strong>Estimate unknown</strong> — more evidence is needed.</p>");
    try w.writeAll("<ul class=\"cp-plain-list wb-m3-signals\">");
    for (meter.signals) |signal| try w.print("<li><strong>{s}</strong>: {s}</li>", .{ lib.ui.escapeSafe(req.allocator, signal.label), lib.ui.escapeSafe(req.allocator, signal.evidence) });
    try w.writeAll("</ul></div></article>");
}

fn renderLiveMeter(req: mer.Request, w: *std.Io.Writer, meter: lib.types.TopicMeterResponse) !void {
    try w.print("<article class=\"wb-m3-meter-card\"><div><p class=\"eyebrow\">{s}</p><h3>{s}</h3><p>{d} observations · {d:.0}% confidence · {s}</p></div><div>", .{ lib.ui.escapeSafe(req.allocator, meter.state), lib.ui.escapeSafe(req.allocator, meter.topic), meter.evidence_count, meter.evidence_confidence * 100, if (meter.stale) "stale" else "current" });
    if (lib.m3.meterPercent(meter.estimated_completion)) |value| try w.print("<label>Measured completion <meter min=\"0\" max=\"100\" value=\"{d}\">{d}%</meter><strong>{d}%</strong></label>", .{ value, value, value }) else try w.writeAll("<p class=\"cp-unknown-meter\"><strong>Estimate uncertain</strong> — insufficient evidence for a percentage.</p>");
    try w.writeAll("<ul class=\"cp-plain-list wb-m3-signals\">");
    for (meter.signals) |signal| try w.print("<li><strong>{s}</strong>: {d} evidence item(s){s}</li>", .{ lib.ui.escapeSafe(req.allocator, signal.name), signal.evidence_count, if (signal.value == null) " · value uncertain" else "" });
    try w.print("</ul><aside class=\"wb-m3-recommendation\"><strong>Recommended next step</strong><p>{s}</p><a class=\"cp-btn cp-btn-ghost\" href=\"/flashcards\">Review flashcards</a></aside></div></article>", .{lib.ui.escapeSafe(req.allocator, meter.recommendation)});
}
