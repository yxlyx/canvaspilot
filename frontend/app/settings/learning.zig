const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Learning settings" };

const demo_enrollments = [_]lib.types.EnrollmentResponse{.{
    .id = "123e4567-e89b-12d3-a456-426614174000",
    .code = "CS2040S",
    .title = "Data Structures and Algorithms",
    .academic_year = "2025-2026",
    .semester = 1,
    .provenance = "NUSMods module catalog",
    .import_method = "share_url",
    .topic_state = "provisional",
    .evidence_warning = "Topics are provisional until reviewed against your syllabus.",
    .archived = false,
    .institution = "NUS",
    .provider = "nusmods",
    .provider_version = "2025-2026",
    .provider_academic_year = "2025-2026",
    .source_url = "https://api.nusmods.com/v2/2025-2026/moduleInfo/CS2040S.json",
    .provider_fetched_at = "2025-07-24T10:30:00Z",
    .payload_sha256 = "5f98d34e0b72460dc61c056f3a12bc6c3890a620cc0b608da9f81a5f71bb327a",
}};

fn renderEnrollment(req: mer.Request, w: anytype, enrollment: lib.types.EnrollmentResponse, demo: bool) !void {
    const warning = enrollment.evidence_warning orelse "Topics are provisional until reviewed against your syllabus.";
    try w.print("<article class=\"cp-enrollment-card{s}\" data-enrollment-id=\"{s}\"><header><div><p class=\"eyebrow\">{s} · {s}</p><h3>{s} — {s}</h3><p>{s} · Semester {d} · Imported via {s}</p></div><span class=\"cp-state\">{s}</span></header>", .{ if (enrollment.archived) " is-archived" else "", lib.ui.escapeSafe(req.allocator, enrollment.id), lib.ui.escapeSafe(req.allocator, enrollment.institution), lib.ui.escapeSafe(req.allocator, enrollment.code), lib.ui.escapeSafe(req.allocator, enrollment.code), lib.ui.escapeSafe(req.allocator, enrollment.title), lib.ui.escapeSafe(req.allocator, enrollment.academic_year), enrollment.semester, lib.ui.escapeSafe(req.allocator, enrollment.import_method), if (enrollment.archived) "Archived" else lib.ui.escapeSafe(req.allocator, enrollment.topic_state) });
    try w.print("<div class=\"cp-provisional-warning\" role=\"note\"><strong>Provisional topic map.</strong> {s} Existing enrollments remain unless you explicitly archive them.</div>", .{lib.ui.escapeSafe(req.allocator, warning)});
    try w.print("<details class=\"cp-provenance\"><summary>Provider snapshot provenance</summary><dl><div><dt>Provider</dt><dd>{s} · version {s}</dd></div><div><dt>Academic year</dt><dd>{s}</dd></div><div><dt>Fetched</dt><dd>{s}</dd></div><div><dt>Payload SHA-256</dt><dd><code>{s}</code></dd></div><div><dt>Source</dt><dd><a href=\"{s}\" rel=\"noreferrer\">Open provider snapshot</a></dd></div><div><dt>Identity</dt><dd>Local enrollment <code>{s}</code></dd></div></dl></details>", .{ lib.ui.escapeSafe(req.allocator, enrollment.provider), lib.ui.escapeSafe(req.allocator, enrollment.provider_version), lib.ui.escapeSafe(req.allocator, enrollment.provider_academic_year), lib.ui.escapeSafe(req.allocator, enrollment.provider_fetched_at), lib.ui.escapeSafe(req.allocator, enrollment.payload_sha256), lib.ui.escapeSafe(req.allocator, lib.m3.safeSourceHref(enrollment.source_url, "/settings/learning")), lib.ui.escapeSafe(req.allocator, enrollment.id) });
    try w.writeAll("<footer>");
    if (!enrollment.archived) {
        try w.print("<a class=\"cp-btn cp-btn-primary\" href=\"/learning/{s}{s}\">Open knowledge dashboard</a>", .{ lib.ui.escapeSafe(req.allocator, enrollment.id), if (demo) "?mock=1" else "" });
        try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"/sources?enrollment_id={s}{s}\">Use this module</a>", .{ lib.ui.escapeSafe(req.allocator, enrollment.id), if (demo) "&amp;mock=1" else "" });
    }
    if (demo) try w.writeAll("<span class=\"cp-settings-readonly\">Synthetic fixture · topic changes disabled</span>") else try w.writeAll("<button class=\"cp-btn cp-btn-ghost\" type=\"button\" data-review-topics>Review canonical topics</button>");
    try w.writeAll("</footer><section class=\"cp-topic-review\" hidden data-topic-review aria-live=\"polite\"></section></article>");
}

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Learning settings")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const token = lib.session.fromRequest(req).token;
    const preferences = if (demo) demoPreferences() else blk: {
        const result = lib.backend.preferences(req.allocator, token);
        break :blk if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Learning settings", result.status);
    };
    const policy = if (demo) demoPolicy() else blk: {
        const result = lib.backend.processingPolicy(req.allocator, token);
        break :blk if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Processing policy", result.status);
    };
    const module_result = if (demo) null else lib.backend.listModules(req.allocator, token);
    const modules = if (demo) lib.mock.modules else if (module_result.?.value) |parsed| parsed.value else &.{};
    const enrollment_result = if (demo) null else lib.backend.listEnrollments(req.allocator, token);
    const enrollments: []const lib.types.EnrollmentResponse = if (demo) &demo_enrollments else if (enrollment_result.?.value) |parsed| parsed.value else &.{};
    const scopes_loaded = demo or (module_result.?.value != null and enrollment_result.?.value != null);

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("learning render failed");
    lib.settings_ui.heading(req, w, "learning", "Module scope", "Learning", "Import your modules, verify their topic maps, and choose a stable local learning scope.", demo) catch return mer.internalError("learning render failed");
    if (req.queryParam("import")) |outcome| {
        if (std.mem.eql(u8, outcome, "success")) w.writeAll("<div class=\"notice notice-success\" role=\"status\"><strong>Module import confirmed</strong><span>Your enrollment list below includes the saved selection.</span></div>") catch return mer.internalError("learning render failed") else if (std.mem.eql(u8, outcome, "partial")) w.writeAll("<div class=\"notice notice-warn\" role=\"status\"><strong>Module import partly completed</strong><span>Successful selections are saved. Review the enrollment list and retry only the unavailable modules.</span></div>") catch return mer.internalError("learning render failed");
    }

    w.writeAll("<div class=\"cp-learning-workflow\"><section class=\"cp-settings-section cp-import-section\"><header><div><p class=\"eyebrow\">1 · Import</p><h2>Add modules from NUSMods</h2><p>A share link and manual module codes use the same validated preview. Nothing changes until you confirm.</p></div></header><form data-module-import novalidate><fieldset") catch return mer.internalError("learning render failed");
    if (demo) w.writeAll(" disabled") catch return mer.internalError("learning render failed");
    w.writeAll("><legend>Import method</legend><div class=\"cp-import-methods\"><label><input type=\"radio\" name=\"import_method\" value=\"share_url\" checked> NUSMods share URL</label><label><input type=\"radio\" name=\"import_method\" value=\"manual_codes\"> Manual module codes</label></div><label class=\"cp-field\" data-share-field><span>NUSMods share URL</span><input name=\"share_url\" type=\"url\" inputmode=\"url\" placeholder=\"https://nusmods.com/timetable/sem-1/share?...\" autocomplete=\"off\"><small>Use a timetable share URL. Unsupported or malformed links will not be imported.</small></label><label class=\"cp-field\" data-codes-field hidden><span>Module codes</span><input name=\"module_codes\" placeholder=\"CS2040S, MA1521\" autocomplete=\"off\"><small>Up to 30 alphanumeric codes, separated by commas or spaces.</small></label><div class=\"cp-confirm-fields\"><label class=\"cp-field\"><span>Academic year</span><input name=\"academic_year\" value=\"2025-2026\" pattern=\"[0-9]{4}-[0-9]{4}\" required></label><label class=\"cp-field\"><span>Semester</span><select name=\"semester\" required><option value=\"1\">Semester 1</option><option value=\"2\">Semester 2</option><option value=\"3\">Special Term I</option><option value=\"4\">Special Term II</option></select></label></div><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Preview modules</button></fieldset>") catch return mer.internalError("learning render failed");
    if (demo) w.writeAll("<p class=\"cp-settings-readonly\">Synthetic fixture preview. Imports and changes are disabled.</p>") catch return mer.internalError("learning render failed");
    w.writeAll("<p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p></form><section data-import-preview hidden aria-live=\"polite\"></section></section><section class=\"cp-settings-section\"><header><div><p class=\"eyebrow\">2 · Enrollments</p><h2>Your local modules</h2><p>These identities remain usable even when a learning provider changes.</p></div></header><div class=\"cp-enrollment-list\" data-enrollment-list>") catch return mer.internalError("learning render failed");
    if (!demo and !scopes_loaded) w.writeAll("<div class=\"cp-inline-error\" role=\"alert\"><strong>Module scopes could not be loaded.</strong> Check your connection and retry. Existing defaults and enrollments are preserved.</div>") catch return mer.internalError("learning render failed");
    if (enrollments.len == 0 and (demo or enrollment_result.?.value != null)) w.writeAll("<p class=\"cp-empty-copy\">No local enrollments yet. Preview a share URL or module code above.</p>") catch return mer.internalError("learning render failed");
    for (enrollments) |enrollment| renderEnrollment(req, w, enrollment, demo) catch return mer.internalError("learning render failed");
    w.writeAll("</div></section><section class=\"cp-settings-section cp-processing-policy\"><header><div><p class=\"eyebrow\">3 · Processing policy</p><h2>Choose what happens after intake</h2><p>Each stage is independent. Disabling source processing pauses queued work instead of discarding it.</p></div></header><form data-processing-policy-form><fieldset class=\"cp-settings-fieldset\"") catch return mer.internalError("learning render failed");
    if (demo) w.writeAll(" disabled") catch return mer.internalError("learning render failed");
    w.writeAll("><legend class=\"sr-only\">Processing policy controls</legend><div class=\"cp-policy-grid\"><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"process_sources\"") catch return mer.internalError("learning render failed");
    if (policy.process_sources) w.writeAll(" checked") catch return mer.internalError("learning render failed");
    w.writeAll("> <span><strong>Process source content</strong><small>Parse and index uploads or pasted notes. Links remain bookmark metadata.</small></span></label><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"map_topics\"") catch return mer.internalError("learning render failed");
    if (policy.map_topics) w.writeAll(" checked") catch return mer.internalError("learning render failed");
    w.writeAll("> <span><strong>Deterministic topic mapping</strong><small>Propose curriculum associations only for scoped sources.</small></span></label><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"compile_wiki\"") catch return mer.internalError("learning render failed");
    if (policy.compile_wiki) w.writeAll(" checked") catch return mer.internalError("learning render failed");
    w.print("> <span><strong>Refresh the Wiki</strong><small>Keep the last valid Wiki when a refresh fails.</small></span></label><label class=\"cp-field\"><span>Flashcard generation</span><select name=\"flashcard_mode\"><option value=\"off\"{s}>Off</option><option value=\"suggest\"{s}>Suggest only</option><option value=\"draft\"{s}>Create draft decks</option></select><small>Pipeline decks always require review before practice.</small></label></div></fieldset>", .{ if (std.mem.eql(u8, policy.flashcard_mode, "off")) " selected" else "", if (std.mem.eql(u8, policy.flashcard_mode, "suggest")) " selected" else "", if (std.mem.eql(u8, policy.flashcard_mode, "draft")) " selected" else "" }) catch return mer.internalError("learning render failed");
    if (demo) w.writeAll("<p class=\"cp-settings-readonly\">Synthetic fixture policy. Changes are disabled.</p>") catch return mer.internalError("learning render failed") else w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save processing policy</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p>") catch return mer.internalError("learning render failed");
    w.writeAll("</form></section><section class=\"cp-settings-section\"><header><div><p class=\"eyebrow\">4 · Default</p><h2>Your daily starting point</h2><p>Choose a stable local enrollment scope or an existing connected module.</p></div></header><form method=\"post\" action=\"/api/settings\" data-settings-form><input type=\"hidden\" name=\"action\" value=\"preferences.update\"><input type=\"hidden\" name=\"next\" value=\"/settings/learning\"><fieldset class=\"cp-settings-fieldset\"") catch return mer.internalError("learning render failed");
    if (demo) w.writeAll(" disabled") catch return mer.internalError("learning render failed");
    w.writeAll("><legend class=\"sr-only\">Default learning scope and daily target</legend><label class=\"cp-field\"><span>Default module</span><select name=\"default_scope\"><option value=\"\">Most recently active</option><optgroup label=\"Local enrollments\">") catch return mer.internalError("learning render failed");
    for (enrollments) |enrollment| if (!enrollment.archived) w.print("<option value=\"enrollment:{s}\"{s}>{s} — {s}</option>", .{ lib.ui.escapeSafe(req.allocator, enrollment.id), if (preferences.default_enrollment_id) |id| if (std.mem.eql(u8, id, enrollment.id)) " selected" else "" else "", lib.ui.escapeSafe(req.allocator, enrollment.code), lib.ui.escapeSafe(req.allocator, enrollment.title) }) catch return mer.internalError("learning render failed");
    w.writeAll("</optgroup><optgroup label=\"Connected modules\">") catch return mer.internalError("learning render failed");
    for (modules) |module| w.print("<option value=\"module:{s}\"{s}>{s} — {s}</option>", .{ lib.ui.escapeSafe(req.allocator, module.id), if (preferences.default_module_id) |id| if (std.mem.eql(u8, id, module.id)) " selected" else "" else "", lib.ui.escapeSafe(req.allocator, module.code), lib.ui.escapeSafe(req.allocator, module.name) }) catch return mer.internalError("learning render failed");
    w.writeAll("</optgroup></select></label>") catch return mer.internalError("learning render failed");
    if (!demo and scopes_loaded) w.writeAll("<input type=\"hidden\" name=\"scope_loaded\" value=\"1\">") catch return mer.internalError("learning render failed");
    w.print("<label class=\"cp-field\"><span>Daily review target</span><input type=\"number\" name=\"daily_review_target\" value=\"{d}\" min=\"1\" max=\"100\" required></label></fieldset>", .{preferences.daily_review_target}) catch return mer.internalError("learning render failed");
    if (demo) w.writeAll("<p class=\"cp-settings-readonly\">Synthetic fixture preview. Settings are read-only.</p>") catch return mer.internalError("learning render failed") else w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save learning settings</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p>") catch return mer.internalError("learning render failed");
    w.writeAll("</form></section></div><script src=\"/settings.js?v=20260728-1\" defer></script><script src=\"/curriculum.js?v=20260725-1\" defer></script>") catch return mer.internalError("learning render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn demoPolicy() lib.types.ProcessingPolicyResponse {
    return .{ .process_sources = true, .map_topics = true, .compile_wiki = true, .flashcard_mode = "suggest", .require_deck_review = true, .updated_at = "" };
}

fn demoPreferences() lib.types.UserPreferenceResponse {
    return .{ .theme = "system", .motion_preference = "system", .default_module_id = null, .default_enrollment_id = null, .daily_review_target = 10, .reminder_daily_review = true, .reminder_processing_attention = true, .reminder_paper_review = true, .reminder_health_attention = true, .updated_at = "" };
}
