const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Module knowledge", .description = "Review source evidence against an ordered module topic map." };

const demo_enrollment: lib.types.EnrollmentResponse = .{ .id = "123e4567-e89b-12d3-a456-426614174000", .code = "CS2040S", .title = "Data Structures and Algorithms", .academic_year = "2025-2026", .semester = 1, .provenance = "Synthetic curriculum fixture", .import_method = "manual_codes", .topic_state = "canonical", .evidence_warning = null, .archived = false, .institution = "NUS", .provider = "synthetic", .provider_version = "fixture-1", .provider_academic_year = "2025-2026", .source_url = "", .provider_fetched_at = "2025-07-25T00:00:00Z", .payload_sha256 = "synthetic-fixture" };

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const enrollment_id = req.param("enrollment_id") orelse return mer.badRequest("invalid enrollment identifier");
    if (!safeUuid(enrollment_id)) return mer.badRequest("invalid enrollment identifier");
    const demo = lib.m3.isExplicitDemo(req);
    const enrollment = if (demo) demo_enrollment else blk: {
        const result = lib.backend.listEnrollments(req.allocator, lib.session.fromRequest(req).token);
        const enrollments = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Module knowledge", result.status);
        for (enrollments) |item| if (std.mem.eql(u8, item.id, enrollment_id) and !item.archived) break :blk item;
        return lib.m3.liveError(req, "Module knowledge", 404);
    };

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("knowledge dashboard render failed");
    w.print("<main id=\"main\" class=\"coverage-page\" data-coverage-dashboard data-enrollment-id=\"{s}\" data-demo=\"{s}\"><nav class=\"coverage-breadcrumb\" aria-label=\"Breadcrumb\"><a href=\"/settings/learning{s}\">Learning settings</a><span aria-hidden=\"true\">/</span><span aria-current=\"page\">{s}</span></nav><header class=\"coverage-header\"><div><p class=\"eyebrow\">{s} · {s} · Semester {d}</p><h1>{s} — {s}</h1><p>Curriculum state: <strong>{s}</strong></p></div><section class=\"coverage-metric\" aria-labelledby=\"coverage-metric-title\"><p id=\"coverage-metric-title\">Confirmed source coverage</p><strong data-coverage-metric>Loading…</strong><span data-coverage-percentage></span></section></header>", .{ lib.ui.escapeSafe(req.allocator, enrollment.id), if (demo) "true" else "false", if (demo) "?mock=1" else "", lib.ui.escapeSafe(req.allocator, enrollment.code), lib.ui.escapeSafe(req.allocator, enrollment.institution), lib.ui.escapeSafe(req.allocator, enrollment.academic_year), enrollment.semester, lib.ui.escapeSafe(req.allocator, enrollment.code), lib.ui.escapeSafe(req.allocator, enrollment.title), lib.ui.escapeSafe(req.allocator, enrollment.topic_state) }) catch return mer.internalError("knowledge dashboard render failed");
    w.writeAll("<section class=\"coverage-disclosure\" aria-labelledby=\"source-coverage-title\" role=\"note\"><div><p class=\"eyebrow\">Source coverage</p><h2 id=\"source-coverage-title\">Source coverage, not mastery.</h2><span>This section records reviewed source evidence for canonical curriculum topics. It does not measure what you know.</span></div></section><div class=\"coverage-warning\" data-coverage-warning role=\"alert\" tabindex=\"-1\" hidden></div><p class=\"coverage-status\" data-coverage-status role=\"status\" tabindex=\"-1\">Loading current evidence…</p><section class=\"coverage-workspace\" aria-labelledby=\"topic-coverage-title\"><div class=\"coverage-section-heading\"><div><p class=\"eyebrow\">Ordered curriculum</p><h2 id=\"topic-coverage-title\">Source evidence by topic</h2></div><button class=\"cp-btn cp-btn-primary\" type=\"button\" data-recompute>Recompute proposals</button></div><div class=\"coverage-table-wrap\" data-topic-table aria-busy=\"true\"></div></section><section class=\"learning-metric-panel\" aria-labelledby=\"recall-title\" data-recall-panel aria-busy=\"true\"><div class=\"coverage-section-heading\"><div><p class=\"eyebrow\">Self-reported recall</p><h2 id=\"recall-title\">Recent approved-card ratings</h2><p><strong>Self-reported recall, not mastery.</strong> Percentages appear only when the API threshold is met.</p></div></div><div data-recall-content><p>Loading recall evidence…</p></div></section><section class=\"learning-metric-panel\" aria-labelledby=\"activity-title\" data-activity-panel aria-busy=\"true\"><div class=\"coverage-section-heading\"><div><p class=\"eyebrow\">Activity volume</p><h2 id=\"activity-title\">Events in the reporting window</h2><p>Counts only; activity does not imply completion or learning.</p></div></div><div data-activity-content><p>Loading activity…</p></div></section><details class=\"learning-methodology\" data-methodology><summary>Methodology and metric details</summary><div data-methodology-content><p>Loading formulas and thresholds from the API…</p></div></details><section class=\"coverage-candidates\" aria-labelledby=\"candidate-title\"><div class=\"coverage-section-heading\"><div><p class=\"eyebrow\">Owned sources</p><h2 id=\"candidate-title\">Candidate sources</h2><p>Processing and failed sources cannot be associated. Sources attached elsewhere are never reassigned automatically.</p></div></div><div data-candidate-list aria-busy=\"true\"></div><form data-manual-association><fieldset><legend>Manually confirm reviewed evidence</legend><label>Topic<select name=\"topic_id\" required><option value=\"\">Select a topic</option></select></label><label>Ready source<select name=\"source_id\" required><option value=\"\">Select a source</option></select></label><div><span id=\"evidence-options-label\">Evidence excerpts <span>(select 1–20)</span></span><div data-evidence-options aria-labelledby=\"evidence-options-label\" aria-live=\"polite\">Select a topic and ready source to load evidence.</div></div><p>This explicit review confirms only the selected source excerpts for the selected topic.</p><button class=\"cp-btn cp-btn-primary\" type=\"submit\" disabled>Confirm manual evidence</button></fieldset></form></section></main><script src=\"/coverage-dashboard.js?v=20260726-2\" defer></script>") catch return mer.internalError("knowledge dashboard render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

test "learning dashboard path identifiers are UUIDs" {
    try std.testing.expect(safeUuid("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expect(!safeUuid("../settings/learning"));
}
