const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Source health", .description = "Review source coverage, freshness, and processing findings." };

fn renderProcessingPolicy(w: *std.Io.Writer, policy: ?lib.types.ProcessingPolicyResponse, demo: bool) !void {
    try w.writeAll("<section class=\"cp-health-policy\" id=\"processing-policy\" aria-labelledby=\"processing-policy-title\"><header><div><p class=\"eyebrow\">Processing controls</p><h2 id=\"processing-policy-title\">Source processing defaults</h2><p>Choose which evidence-building stages run after source intake. Paused work remains saved.</p></div></header>");
    const value = policy orelse {
        try w.writeAll("<div class=\"cp-inline-error\" role=\"alert\"><strong>Processing controls could not be loaded.</strong> Existing settings are unchanged. Reload before editing them.</div></section>");
        return;
    };
    try w.writeAll("<form data-processing-policy-form><fieldset class=\"cp-settings-fieldset\"");
    if (demo) try w.writeAll(" disabled");
    try w.writeAll("><legend class=\"sr-only\">Source processing defaults</legend><div class=\"cp-policy-grid\"><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"process_sources\"");
    if (value.process_sources) try w.writeAll(" checked");
    try w.writeAll("> <span><strong>Process source content</strong><small>Parse and index uploads or pasted notes. Links remain bookmark metadata.</small></span></label><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"map_topics\"");
    if (value.map_topics) try w.writeAll(" checked");
    try w.writeAll("> <span><strong>Propose topic mapping</strong><small>Suggest curriculum associations only for module-scoped sources.</small></span></label><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"compile_wiki\"");
    if (value.compile_wiki) try w.writeAll(" checked");
    try w.print("> <span><strong>Refresh the Wiki</strong><small>Keep the last valid Wiki if a refresh fails.</small></span></label><label class=\"cp-field\"><span>Flashcard generation</span><select name=\"flashcard_mode\"><option value=\"off\"{s}>Off</option><option value=\"suggest\"{s}>Suggest only</option><option value=\"draft\"{s}>Create draft decks</option></select><small>Generated decks always require review before practice.</small></label></div></fieldset>", .{ if (std.mem.eql(u8, value.flashcard_mode, "off")) " selected" else "", if (std.mem.eql(u8, value.flashcard_mode, "suggest")) " selected" else "", if (std.mem.eql(u8, value.flashcard_mode, "draft")) " selected" else "" });
    if (demo) {
        try w.writeAll("<p class=\"cp-settings-readonly\">Synthetic preview · processing controls are disabled.</p>");
    } else {
        try w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save processing defaults</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p>");
    }
    try w.writeAll("</form></section>");
}

fn demoPolicy() lib.types.ProcessingPolicyResponse {
    return .{ .process_sources = true, .map_topics = true, .compile_wiki = true, .flashcard_mode = "suggest", .require_deck_review = true, .updated_at = "" };
}

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Source health")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const selected = req.queryParam("severity") orelse "all";
    const policy_result = if (demo) null else lib.backend.processingPolicy(req.allocator, lib.session.fromRequest(req).token);
    const policy: ?lib.types.ProcessingPolicyResponse = if (demo) demoPolicy() else if (policy_result.?.value) |parsed| parsed.value else null;
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("health render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Source integrity</p><h1 class=\"cp-page-title\">Health</h1><p class=\"cp-page-sub\">Coverage, freshness, and processing issues that need a closer look.</p></div>") catch return mer.internalError("health render failed");
    if (!demo) w.writeAll("<form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"/sources/health\"><input type=\"hidden\" name=\"action\" value=\"health.run\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Run checks</button><span class=\"cp-form-status\" role=\"status\"></span></form>") catch return mer.internalError("health render failed");
    w.writeAll("</header>") catch return mer.internalError("health render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.source_tabs, "health", "Sources", demo) catch return mer.internalError("health tabs failed");
    if (demo) {
        const summary = lib.mock.health_summary;
        w.print("<section class=\"cp-attention-summary\" aria-label=\"Health summary\"><p><strong>{d} healthy</strong><span>Current and supported</span></p><p><strong>{d} need attention</strong><span>Thin or stale coverage</span></p><p><strong>{d} failed</strong><span>Processing or reference errors</span></p><p><strong>{d} unknown</strong><span>Not checked yet</span></p></section>", .{ summary.healthy, summary.warning + summary.stale, summary.failed, summary.unknown }) catch return mer.internalError("health render failed");
    } else {
        w.writeAll("<section class=\"cp-attention-summary\" aria-label=\"Health summary\"><p><strong>Health findings</strong><span>Resolve failed processing first, then improve thin or stale coverage.</span></p></section>") catch return mer.internalError("health render failed");
    }
    renderProcessingPolicy(w, policy, demo) catch return mer.internalError("health render failed");
    w.writeAll("<nav class=\"cp-filter-row\" aria-label=\"Health status\">") catch return mer.internalError("health render failed");
    filter(req, w, "All", "all", selected, demo) catch return mer.internalError("health render failed");
    filter(req, w, "Healthy", "info", selected, demo) catch return mer.internalError("health render failed");
    filter(req, w, "Warning", "warning", selected, demo) catch return mer.internalError("health render failed");
    filter(req, w, "Failed", "error", selected, demo) catch return mer.internalError("health render failed");
    w.writeAll("</nav><section class=\"cp-editorial-ledger cp-health-ledger\" aria-label=\"Findings\">") catch return mer.internalError("health render failed");
    var shown: usize = 0;
    if (demo) {
        for (lib.mock.health_findings) |finding| {
            const matches = std.mem.eql(u8, selected, "all") or std.mem.eql(u8, selected, @tagName(finding.severity)) or (std.mem.eql(u8, selected, "error") and finding.severity == .critical);
            if (!matches) continue;
            shown += 1;
            const path = std.fmt.allocPrint(req.allocator, "/sources/health/{s}", .{lib.m3.safeId(finding.id, "")}) catch return mer.internalError("health render failed");
            const href = lib.m3.demoHrefFor(req.allocator, true, path) catch return mer.internalError("health render failed");
            w.print("<article><div><span class=\"cp-state status-pill\">{s}</span><h2><a href=\"{s}\">{s}</a></h2><p>{s}</p></div><div><strong>{s}</strong><p>{s}</p></div></article>", .{ @tagName(finding.state), href, lib.ui.escapeSafe(req.allocator, finding.title), lib.ui.escapeSafe(req.allocator, finding.detail), lib.ui.escapeSafe(req.allocator, finding.subject), lib.ui.escapeSafe(req.allocator, finding.recommendation) }) catch return mer.internalError("health render failed");
        }
    } else {
        const result = lib.backend.listHealth(req.allocator, lib.session.fromRequest(req).token);
        const findings = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Source health", result.status);
        for (findings) |finding| {
            if (!std.mem.eql(u8, selected, "all") and !std.mem.eql(u8, selected, finding.severity)) continue;
            shown += 1;
            w.print("<article><div><span class=\"cp-state status-pill\">{s} · {s}</span><h2><a href=\"/sources/health/{s}\">{s}</a></h2><p>{s}</p></div><div><strong>Recommended action</strong><p>{s}</p></div></article>", .{ lib.ui.escapeSafe(req.allocator, finding.state), lib.ui.escapeSafe(req.allocator, finding.severity), lib.ui.escapeSafe(req.allocator, finding.id), lib.ui.escapeSafe(req.allocator, finding.code), lib.ui.escapeSafe(req.allocator, finding.message), lib.ui.escapeSafe(req.allocator, finding.recommendation) }) catch return mer.internalError("health render failed");
        }
    }
    if (shown == 0) w.writeAll("<div class=\"cp-empty\"><div><h2>No findings here</h2><p>There are no source findings for this status.</p></div></div>") catch return mer.internalError("health render failed");
    w.writeAll("</section><script src=\"/m3.js?v=20260722\" defer></script><script src=\"/settings.js?v=20260728-1\" defer></script>") catch return mer.internalError("health render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn filter(req: mer.Request, w: *std.Io.Writer, label: []const u8, value: []const u8, selected: []const u8, demo: bool) !void {
    const path = if (std.mem.eql(u8, value, "all")) "/sources/health" else try std.fmt.allocPrint(req.allocator, "/sources/health?severity={s}", .{value});
    const href = try lib.m3.demoHrefFor(req.allocator, demo, path);
    try w.print("<a class=\"filter-button{s}\" href=\"{s}\"{s}>{s}</a>", .{ if (std.mem.eql(u8, value, selected)) " active" else "", href, if (std.mem.eql(u8, value, selected)) " aria-current=\"page\"" else "", label });
}
