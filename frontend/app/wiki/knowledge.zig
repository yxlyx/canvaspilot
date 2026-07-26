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
        w.writeAll("<section class=\"wb-m3-overview cp-knowledge-summary\"><div><p class=\"eyebrow\">Illustrative evidence layout</p><h2>No synthetic knowledge score.</h2><p>Demo evidence shows presentation states only; it is never treated as a measured result.</p></div><div class=\"cp-knowledge-ring cp-knowledge-ring-unknown\" role=\"img\" aria-label=\"Knowledge completion is not measured in the demo\"><strong>—</strong><span>not measured</span></div>") catch return mer.internalError("knowledge render failed");
        w.writeAll("</section><section class=\"cp-settings-ledger cp-knowledge-ledger\" aria-labelledby=\"topic-ledger\"><header><div><p class=\"eyebrow\">Topic ledger</p><h2 id=\"topic-ledger\">Topic evidence</h2></div></header>") catch return mer.internalError("knowledge render failed");
        for (lib.mock.knowledge_meters) |meter| renderMockMeter(req, w, meter) catch return mer.internalError("knowledge render failed");
        w.writeAll("</section>") catch return mer.internalError("knowledge render failed");
    } else {
        const result = lib.backend.topicMeters(req.allocator, lib.session.fromRequest(req).token);
        const meters = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Knowledge", result.status);
        w.writeAll("<section class=\"wb-m3-overview cp-knowledge-summary\"><div><p class=\"eyebrow\">Current evidence</p><h2>What your workspace can support.</h2><p>Completion appears only where there is enough recent evidence.</p></div><div class=\"cp-knowledge-ring cp-knowledge-ring-unknown\" role=\"img\" aria-label=\"Knowledge completion is not yet measured\"><strong>—</strong><span>topic-level evidence</span></div></section><section class=\"cp-settings-ledger cp-knowledge-ledger\" aria-labelledby=\"topic-ledger\"><header><div><p class=\"eyebrow\">Topic ledger</p><h2 id=\"topic-ledger\">Topic evidence</h2></div></header>") catch return mer.internalError("knowledge render failed");
        for (meters) |meter| renderLiveMeter(req, w, meter) catch return mer.internalError("knowledge render failed");
        if (meters.len == 0) w.writeAll("<div class=\"cp-empty\"><div><h3>No measured topics yet</h3><p>Review flashcards or marked work to create learning evidence.</p></div></div>") catch return mer.internalError("knowledge render failed");
        w.writeAll("</section>") catch return mer.internalError("knowledge render failed");
    }
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderMockMeter(req: mer.Request, w: *std.Io.Writer, meter: lib.types.KnowledgeMeter) !void {
    try w.print("<article class=\"wb-m3-meter-card\"><div><p class=\"eyebrow\">{s} confidence</p><h3>{s}</h3><p>{d} evidence signals · {s}</p></div><div>", .{ lib.ui.escapeSafe(req.allocator, meter.confidence), lib.ui.escapeSafe(req.allocator, meter.topic), meter.evidence_count, lib.ui.escapeSafe(req.allocator, meter.recency) });
    try w.writeAll("<p class=\"cp-unknown-meter\"><strong>Not measured</strong> — illustrative demo signals do not produce a score.</p>");
    try w.writeAll("<ul class=\"cp-plain-list wb-m3-signals\">");
    for (meter.signals) |signal| try w.print("<li><strong>{s}</strong>: {s}</li>", .{ lib.ui.escapeSafe(req.allocator, signal.label), lib.ui.escapeSafe(req.allocator, signal.evidence) });
    if (mockRecommendation(meter.id)) |recommendation| {
        try w.print("</ul><aside class=\"wb-m3-recommendation\"><strong>{s}</strong><p>{s}</p><p><strong>Evidence:</strong> {s}</p><p><strong>Next:</strong> {s}</p><div class=\"cp-action-row\">", .{ lib.ui.escapeSafe(req.allocator, recommendation.title), lib.ui.escapeSafe(req.allocator, recommendation.why), lib.ui.escapeSafe(req.allocator, recommendation.evidence), lib.ui.escapeSafe(req.allocator, recommendation.next_action) });
        for (recommendation.actions) |action| {
            const safe_href = lib.m3.safeInternalHref(action.href, "/wiki/knowledge");
            const canonical_href = if (std.mem.startsWith(u8, safe_href, "/marked-papers/"))
                try std.fmt.allocPrint(req.allocator, "/sources/papers/{s}", .{safe_href[15..]})
            else
                safe_href;
            const href = try lib.m3.demoHref(req.allocator, req, canonical_href);
            try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"{s}\">{s}</a>", .{ lib.ui.escapeSafe(req.allocator, href), lib.ui.escapeSafe(req.allocator, action.label) });
        }
        try w.writeAll("</div></aside></div></article>");
        return;
    }
    try w.writeAll("</ul></div></article>");
}

fn renderLiveMeter(req: mer.Request, w: *std.Io.Writer, meter: lib.types.TopicMeterResponse) !void {
    const state_label = if (std.mem.eql(u8, meter.state, "measured")) "Evidence available" else if (std.mem.eql(u8, meter.state, "insufficient")) "More evidence needed" else "Not measured";
    try w.print("<article class=\"wb-m3-meter-card\"><div><p class=\"eyebrow\">{s}</p><h3>{s}</h3><p>{d} factual signal(s) · {s}</p></div><div>", .{ state_label, lib.ui.escapeSafe(req.allocator, meter.topic), meter.evidence_count, if (meter.stale) "needs refreshing" else "current" });
    try w.writeAll("<p class=\"cp-unknown-meter\"><strong>No completion score yet.</strong> Open the learning settings to review source coverage, self-reported recall, and activity separately.</p>");
    try w.writeAll("<ul class=\"cp-plain-list wb-m3-signals\">");
    for (meter.signals) |signal| try w.print("<li><strong>{s}</strong>: {d} evidence item(s){s}</li>", .{ lib.ui.escapeSafe(req.allocator, signal.name), signal.evidence_count, if (signal.value == null) " · value uncertain" else "" });
    try w.print("</ul><aside class=\"wb-m3-recommendation\"><strong>Next step</strong><p>{s}</p><div class=\"cp-action-row\"><a class=\"cp-btn cp-btn-ghost\" href=\"/settings/learning\">Open learning settings</a></div></aside></div></article>", .{lib.ui.escapeSafe(req.allocator, meter.recommendation)});
}

fn mockRecommendation(topic_id: []const u8) ?lib.types.KnowledgeRecommendation {
    for (lib.mock.recommendations) |recommendation| if (std.mem.eql(u8, recommendation.topic_id, topic_id)) return recommendation;
    return null;
}
