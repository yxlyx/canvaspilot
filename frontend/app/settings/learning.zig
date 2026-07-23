const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Learning settings" };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Learning settings")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const token = lib.session.fromRequest(req).token;
    const preferences = if (demo) demoPreferences() else blk: {
        const result = lib.backend.preferences(req.allocator, token);
        break :blk if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Learning settings", result.status);
    };
    const modules = if (demo) lib.mock.modules else blk: {
        const result = lib.backend.listModules(req.allocator, token);
        break :blk if (result.value) |parsed| parsed.value else &.{};
    };
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("learning render failed");
    lib.settings_ui.heading(req, w, "learning", "Review rhythm", "Learning", "Set a useful starting scope and a realistic daily review goal.", demo) catch return mer.internalError("learning render failed");
    w.writeAll("<div class=\"cp-settings-column\"><section class=\"cp-settings-section\"><header><div><p class=\"eyebrow\">Defaults</p><h2>Your daily starting point</h2><p>These choices guide the workspace; they do not change evidence or mastery estimates.</p></div></header><form method=\"post\" action=\"/api/settings\" data-settings-form><input type=\"hidden\" name=\"action\" value=\"preferences.update\"><input type=\"hidden\" name=\"next\" value=\"/settings/learning\"><label class=\"cp-field\"><span>Default module</span><select name=\"default_module_id\"><option value=\"\">Most recently active</option>") catch return mer.internalError("learning render failed");
    for (modules) |module| w.print("<option value=\"{s}\"{s}>{s} — {s}</option>", .{ lib.ui.escapeSafe(req.allocator, module.id), if (preferences.default_module_id) |id| if (std.mem.eql(u8, id, module.id)) " selected" else "" else "", lib.ui.escapeSafe(req.allocator, module.code), lib.ui.escapeSafe(req.allocator, module.name) }) catch return mer.internalError("learning render failed");
    w.print("</select></label><label class=\"cp-field\"><span>Daily review target</span><input type=\"number\" name=\"daily_review_target\" value=\"{d}\" min=\"1\" max=\"100\" list=\"review-targets\" required><datalist id=\"review-targets\"><option value=\"5\"><option value=\"10\"><option value=\"20\"><option value=\"30\"></datalist></label><p class=\"cp-settings-explanation\"><strong>A review goal, not a due score.</strong> This target counts completed card reviews today. It does not claim mastery or alter spaced repetition scheduling.</p>", .{preferences.daily_review_target}) catch return mer.internalError("learning render failed");
    if (demo) w.writeAll("<p class=\"cp-settings-readonly\">This synthetic preview is read-only.</p>") catch return mer.internalError("learning render failed") else w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save learning settings</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p>") catch return mer.internalError("learning render failed");
    w.writeAll("</form></section></div><script src=\"/settings.js?v=20260722\" defer></script>") catch return mer.internalError("learning render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn demoPreferences() lib.types.UserPreferenceResponse {
    return .{ .theme = "system", .motion_preference = "system", .default_module_id = null, .daily_review_target = 10, .reminder_daily_review = true, .reminder_processing_attention = true, .reminder_paper_review = true, .reminder_health_attention = true, .updated_at = "" };
}
