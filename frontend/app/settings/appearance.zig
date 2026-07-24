const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Appearance settings" };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Appearance settings")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const preferences = if (demo) demoPreferences() else blk: {
        const result = lib.backend.preferences(req.allocator, lib.session.fromRequest(req).token);
        break :blk if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Appearance settings", result.status);
    };
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("appearance render failed");
    lib.settings_ui.heading(req, w, "appearance", "Reading environment", "Appearance", "Choose how WikiBase follows your device and respects motion preferences.", demo) catch return mer.internalError("appearance render failed");
    w.writeAll("<div class=\"cp-settings-column\"><section class=\"cp-settings-section\"><header><div><p class=\"eyebrow\">Theme</p><h2>Choose a surface</h2><p>System follows your device. Your choice is applied before the page paints.</p></div></header><form method=\"post\" action=\"/api/settings\" data-settings-form data-appearance-form><input type=\"hidden\" name=\"action\" value=\"preferences.update\"><input type=\"hidden\" name=\"next\" value=\"/settings/appearance\"><fieldset class=\"cp-theme-choices\"><legend>Theme</legend>") catch return mer.internalError("appearance render failed");
    themeChoice(w, "system", "System", "Follow the operating system", preferences.theme) catch return mer.internalError("appearance render failed");
    themeChoice(w, "light", "Light", "Warm paper and charcoal type", preferences.theme) catch return mer.internalError("appearance render failed");
    themeChoice(w, "dark", "Dark", "Charcoal surfaces and soft grey contrast", preferences.theme) catch return mer.internalError("appearance render failed");
    w.print("</fieldset><fieldset class=\"cp-setting-radios\"><legend>Motion</legend><label><input type=\"radio\" name=\"motion_preference\" value=\"system\"{s}><span><strong>Follow system</strong><small>Use your device motion preference.</small></span></label><label><input type=\"radio\" name=\"motion_preference\" value=\"reduce\"{s}><span><strong>Reduce motion</strong><small>Keep transitions and movement to a minimum.</small></span></label></fieldset>", .{ if (equal(preferences.motion_preference, "system")) " checked" else "", if (equal(preferences.motion_preference, "reduce")) " checked" else "" }) catch return mer.internalError("appearance render failed");
    if (demo) w.writeAll("<p class=\"cp-settings-readonly\">Theme previews work in this synthetic view, but account preferences are not saved.</p>") catch return mer.internalError("appearance render failed") else w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save appearance</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p>") catch return mer.internalError("appearance render failed");
    w.writeAll("</form></section></div><script src=\"/settings.js?v=20260724-2\" defer></script>") catch return mer.internalError("appearance render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn demoPreferences() lib.types.UserPreferenceResponse {
    return .{ .theme = "system", .motion_preference = "system", .default_module_id = null, .daily_review_target = 10, .reminder_daily_review = true, .reminder_processing_attention = true, .reminder_paper_review = true, .reminder_health_attention = true, .updated_at = "" };
}

fn equal(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}

fn themeChoice(w: *@import("std").Io.Writer, value: []const u8, label: []const u8, detail: []const u8, selected: []const u8) !void {
    try w.print("<label class=\"cp-theme-choice cp-theme-choice-{s}\"><input type=\"radio\" name=\"theme\" value=\"{s}\"{s}><span class=\"cp-theme-preview\"><i></i><i></i><i></i></span><span><strong>{s}</strong><small>{s}</small></span></label>", .{ value, value, if (equal(selected, value)) " checked" else "", label, detail });
}
