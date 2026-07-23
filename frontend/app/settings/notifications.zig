const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Notification settings" };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Notification settings")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const preferences = if (demo) demoPreferences() else blk: {
        const result = lib.backend.preferences(req.allocator, lib.session.fromRequest(req).token);
        break :blk if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Notification settings", result.status);
    };
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("notification settings render failed");
    lib.settings_ui.heading(req, w, "notifications", "In-app reminders", "Notifications", "Choose which actionable workspace events appear in your notification inbox.", demo) catch return mer.internalError("notification settings render failed");
    w.writeAll("<div class=\"cp-settings-column\"><section class=\"cp-settings-section\"><header><div><p class=\"eyebrow\">Delivery</p><h2>Only inside WikiBase</h2><p>No email or push controls are shown because those delivery channels are not active.</p></div><a class=\"cp-btn cp-btn-ghost\" href=\"/notifications\">Open inbox</a></header><form method=\"post\" action=\"/api/settings\" data-settings-form><input type=\"hidden\" name=\"action\" value=\"preferences.notifications\"><input type=\"hidden\" name=\"next\" value=\"/settings/notifications\"><fieldset class=\"cp-notification-choices\"><legend>Notify me when</legend>") catch return mer.internalError("notification settings render failed");
    choice(w, "reminder_daily_review", "My daily review target is unfinished", "Created at most once per day when the goal is incomplete.", preferences.reminder_daily_review) catch return mer.internalError("notification settings render failed");
    choice(w, "reminder_processing_attention", "A source needs processing attention", "Failed imports and documents that need intervention.", preferences.reminder_processing_attention) catch return mer.internalError("notification settings render failed");
    choice(w, "reminder_paper_review", "A marked paper is ready for review", "Extracted questions are waiting for confirmation.", preferences.reminder_paper_review) catch return mer.internalError("notification settings render failed");
    choice(w, "reminder_health_attention", "A health finding needs action", "Warnings and failures affecting evidence quality.", preferences.reminder_health_attention) catch return mer.internalError("notification settings render failed");
    w.writeAll("</fieldset>") catch return mer.internalError("notification settings render failed");
    if (demo) w.writeAll("<p class=\"cp-settings-readonly\">This synthetic preview is read-only.</p>") catch return mer.internalError("notification settings render failed") else w.writeAll("<button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save notifications</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p>") catch return mer.internalError("notification settings render failed");
    w.writeAll("</form></section></div><script src=\"/settings.js?v=20260724\" defer></script>") catch return mer.internalError("notification settings render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn choice(w: *@import("std").Io.Writer, name: []const u8, title: []const u8, detail: []const u8, enabled: bool) !void {
    try w.print("<label class=\"cp-notification-choice\"><span><strong>{s}</strong><small>{s}</small></span><input type=\"checkbox\" name=\"{s}\" value=\"true\"{s}></label>", .{ title, detail, name, lib.settings_ui.checked(enabled) });
}

fn demoPreferences() lib.types.UserPreferenceResponse {
    return .{ .theme = "system", .motion_preference = "system", .default_module_id = null, .daily_review_target = 10, .reminder_daily_review = true, .reminder_processing_attention = true, .reminder_paper_review = true, .reminder_health_attention = true, .updated_at = "" };
}
