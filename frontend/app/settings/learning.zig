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
    w.writeAll(
        "<p class=\"cp-form-status cp-import-status\" data-import-status role=\"status\" aria-live=\"polite\" tabindex=\"-1\"></p><noscript><p class=\"cp-inline-error\" role=\"alert\">Module import needs JavaScript to validate the NUSMods snapshot before saving.</p></noscript></form><section class=\"cp-import-preview\" data-import-preview hidden aria-live=\"polite\" tabindex=\"-1\"></section></section></div><script src=\"/curriculum.js?v=20260728-3\" defer></script>",
    ) catch return mer.internalError("module import render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
