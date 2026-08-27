const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Manage modules",
    .description = "Import NUS modules into your learning workspace.",
};

fn renderAcademicYearOptions(w: *std.Io.Writer, current_start: i64) !void {
    for (0..3) |offset| {
        const start = current_start - @as(i64, @intCast(offset));
        try w.print("<option value=\"{d}-{d}\"{s}>{d}–{d}{s}</option>", .{
            start,
            start + 1,
            if (offset == 0) " selected" else "",
            start,
            start + 1,
            if (offset == 0) " · Current" else "",
        });
    }
}

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Manage modules")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const current_academic_year = lib.time.academicYearStart(lib.time.nowSecs(), 7);
    const token = lib.session.fromRequest(req).token;
    const preferences = if (demo) demoPreferences() else blk: {
        const result = lib.backend.preferences(req.allocator, token);
        break :blk if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Learning settings", result.status);
    };
    var enrollments: []const lib.types.EnrollmentResponse = &.{};
    var modules: []const lib.types.Module = if (demo) lib.mock.modules else &.{};
    var scopes_loaded = demo;
    if (!demo) {
        const enrollment_result = lib.backend.listEnrollments(req.allocator, token);
        const module_result = lib.backend.listModules(req.allocator, token);
        if (enrollment_result.value) |parsed| enrollments = parsed.value;
        if (module_result.value) |parsed| modules = parsed.value;
        scopes_loaded = enrollment_result.value != null and module_result.value != null;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("module import render failed");
    lib.settings_ui.heading(
        req,
        w,
        "learning",
        "Modules",
        "Manage modules",
        "Add your NUS modules through a clear, reviewable import.",
        demo,
    ) catch return mer.internalError("module import render failed");

    if (req.queryParam("import")) |outcome| {
        if (std.mem.eql(u8, outcome, "success")) {
            w.writeAll("<div class=\"notice notice-success\" role=\"status\"><strong>Modules imported</strong><span>Your selected modules are now available from the workspace.</span></div>") catch return mer.internalError("module import render failed");
        } else if (std.mem.eql(u8, outcome, "partial")) {
            w.writeAll("<div class=\"notice notice-warn\" role=\"status\"><strong>Some modules need attention</strong><span>Successful modules were saved. Retry only the unavailable modules.</span></div>") catch return mer.internalError("module import render failed");
        }
    }

    w.writeAll(
        "<div class=\"cp-learning-workflow\"><section class=\"cp-settings-section cp-import-section\" aria-labelledby=\"module-import-title\"><header class=\"cp-import-header\"><div><p class=\"eyebrow\">NUSMods import</p><h2 id=\"module-import-title\">Add modules from NUSMods</h2><p>Paste a timetable share link or enter module codes. We validate the catalogue first, then show the exact modules for your confirmation.</p></div><ol class=\"cp-import-steps\" aria-label=\"Import steps\"><li aria-current=\"step\"><span>1</span>Choose</li><li><span>2</span>Review</li><li><span>3</span>Added</li></ol></header><form data-module-import novalidate><fieldset",
    ) catch return mer.internalError("module import render failed");
    if (demo) w.writeAll(" disabled") catch return mer.internalError("module import render failed");
    w.writeAll(
        "><legend>Choose an import method</legend><div class=\"cp-import-methods\"><label><input type=\"radio\" name=\"import_method\" value=\"share_url\" checked><span><strong>NUSMods share link</strong><small>Best for importing your timetable at once.</small></span></label><label><input type=\"radio\" name=\"import_method\" value=\"manual_codes\"><span><strong>Module codes</strong><small>Add up to 30 modules manually.</small></span></label></div><label class=\"cp-field\" data-share-field><span>NUSMods share URL</span><input name=\"share_url\" type=\"url\" inputmode=\"url\" placeholder=\"https://nusmods.com/timetable/sem-1/share?...\" autocomplete=\"off\"><small>Copy the complete share URL from your NUSMods timetable.</small></label><label class=\"cp-field\" data-codes-field hidden><span>Module codes</span><input name=\"module_codes\" placeholder=\"CS2040S, MA1521\" autocomplete=\"off\"><small>Separate module codes with commas or spaces.</small></label><div class=\"cp-confirm-fields\"><label class=\"cp-field\"><span>Academic year</span><select name=\"academic_year\" required>",
    ) catch return mer.internalError("module import render failed");
    renderAcademicYearOptions(w, current_academic_year) catch return mer.internalError("module import render failed");
    w.writeAll(
        "</select></label><label class=\"cp-field\" data-semester-field hidden><span>Semester</span><select name=\"semester\"><option value=\"1\">Semester 1</option><option value=\"2\">Semester 2</option><option value=\"3\">Special Term I</option><option value=\"4\">Special Term II</option></select></label></div><div class=\"cp-import-action\"><button class=\"cp-btn cp-btn-primary cp-import-submit\" type=\"submit\">Import modules</button><p>Nothing is saved until you review and confirm the validated modules.</p></div></fieldset>",
    ) catch return mer.internalError("module import render failed");
    if (demo) {
        w.writeAll("<p class=\"cp-settings-readonly\">Synthetic preview · importing is disabled.</p>") catch return mer.internalError("module import render failed");
    }
    w.writeAll("<p class=\"cp-form-status cp-import-status\" data-import-status role=\"status\" aria-live=\"polite\" tabindex=\"-1\"></p><noscript><p class=\"cp-inline-error\" role=\"alert\">Module import needs JavaScript to validate the NUSMods snapshot before saving.</p></noscript></form><section class=\"cp-import-preview\" data-import-preview hidden aria-live=\"polite\" tabindex=\"-1\"></section></section><section class=\"cp-settings-section cp-study-defaults\" aria-labelledby=\"study-defaults-title\"><header><div><p class=\"eyebrow\">Study defaults</p><h2 id=\"study-defaults-title\">Your daily starting point</h2><p>Choose where WikiBase opens first and set a realistic review goal. This target is not a mastery score.</p></div></header><form method=\"post\" action=\"/api/settings\" data-settings-form><input type=\"hidden\" name=\"action\" value=\"preferences.update\"><input type=\"hidden\" name=\"next\" value=\"/settings/learning\"><fieldset class=\"cp-settings-fieldset\"") catch return mer.internalError("module import render failed");
    if (demo) w.writeAll(" disabled") catch return mer.internalError("module import render failed");
    w.writeAll("><legend class=\"sr-only\">Default module and daily review target</legend><div class=\"cp-study-default-grid\"><label class=\"cp-field\"><span>Default module</span><select name=\"default_scope\"><option value=\"\">Most recently active</option><optgroup label=\"Local enrollments\">") catch return mer.internalError("module import render failed");
    for (enrollments) |enrollment| if (!enrollment.archived) w.print("<option value=\"enrollment:{s}\"{s}>{s} — {s}</option>", .{ lib.ui.escapeSafe(req.allocator, enrollment.id), if (preferences.default_enrollment_id) |id| if (std.mem.eql(u8, id, enrollment.id)) " selected" else "" else "", lib.ui.escapeSafe(req.allocator, enrollment.code), lib.ui.escapeSafe(req.allocator, enrollment.title) }) catch return mer.internalError("module import render failed");
    w.writeAll("</optgroup><optgroup label=\"Connected modules\">") catch return mer.internalError("module import render failed");
    for (modules) |module| w.print("<option value=\"module:{s}\"{s}>{s} — {s}</option>", .{ lib.ui.escapeSafe(req.allocator, module.id), if (preferences.default_module_id) |id| if (std.mem.eql(u8, id, module.id)) " selected" else "" else "", lib.ui.escapeSafe(req.allocator, module.code), lib.ui.escapeSafe(req.allocator, module.name) }) catch return mer.internalError("module import render failed");
    w.writeAll("</optgroup></select><small>Used as the default scope for learning views.</small></label><label class=\"cp-field\"><span>Daily review target</span><input type=\"number\" name=\"daily_review_target\" min=\"1\" max=\"100\" value=\"") catch return mer.internalError("module import render failed");
    w.print("{d}", .{preferences.daily_review_target}) catch return mer.internalError("module import render failed");
    w.writeAll("\" required><small>A review goal from 1 to 100, not a due-card calculation.</small></label></div>") catch return mer.internalError("module import render failed");
    if (!demo and scopes_loaded) w.writeAll("<input type=\"hidden\" name=\"scope_loaded\" value=\"1\">") catch return mer.internalError("module import render failed");
    w.writeAll("</fieldset>") catch return mer.internalError("module import render failed");
    if (demo) w.writeAll("<p class=\"cp-settings-readonly\">Synthetic preview · study defaults are read-only.</p>") catch return mer.internalError("module import render failed") else w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save study defaults</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p>") catch return mer.internalError("module import render failed");
    w.writeAll("</form></section></div><script src=\"/settings.js?v=20260728-1\" defer></script><script src=\"/curriculum.js?v=20260728-3\" defer></script>") catch return mer.internalError("module import render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn demoPreferences() lib.types.UserPreferenceResponse {
    return .{ .theme = "system", .motion_preference = "system", .default_module_id = null, .default_enrollment_id = null, .daily_review_target = 10, .reminder_daily_review = true, .reminder_processing_attention = true, .reminder_paper_review = true, .reminder_health_attention = true, .updated_at = "" };
}
