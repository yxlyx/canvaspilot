const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Account settings", .description = "Manage your WikiBase account." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Account settings")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    const token = lib.session.fromRequest(req).token;
    const user = if (demo) lib.types.User{ .id = "demo-user", .name = "Pranav", .email = "student@example.edu" } else blk: {
        const result = lib.backend.me(req.allocator, token);
        break :blk if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Account settings", result.status);
    };
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("settings render failed");
    lib.settings_ui.heading(req, w, "account", "Personal details and access", "Account", "Keep your identity current and protect access to your workspace.", demo) catch return mer.internalError("settings render failed");
    w.print("<div class=\"cp-settings-column\"><section class=\"cp-settings-section\"><header><div class=\"cp-settings-avatar\">{c}</div><div><p class=\"eyebrow\">Profile</p><h2>{s}</h2><p>{s}</p></div></header>", .{ initial(user.name), lib.ui.escapeSafe(req.allocator, user.name), lib.ui.escapeSafe(req.allocator, user.email) }) catch return mer.internalError("settings render failed");
    if (demo) {
        w.writeAll("<p class=\"cp-settings-readonly\">This synthetic preview is read-only. Sign in to update an account.</p>") catch return mer.internalError("settings render failed");
    } else {
        w.print("<form method=\"post\" action=\"/api/settings\" data-settings-form><input type=\"hidden\" name=\"action\" value=\"profile.update\"><input type=\"hidden\" name=\"next\" value=\"/settings\"><label class=\"cp-field\"><span>Display name</span><input name=\"name\" value=\"{s}\" maxlength=\"255\" autocomplete=\"name\" required></label><label class=\"cp-field\"><span>Email</span><input type=\"email\" value=\"{s}\" readonly aria-describedby=\"email-note\"></label><small id=\"email-note\">Verified email changes are not supported yet.</small><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Save profile</button><p class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></p></form>", .{ lib.ui.escapeSafe(req.allocator, user.name), lib.ui.escapeSafe(req.allocator, user.email) }) catch return mer.internalError("settings render failed");
    }
    w.writeAll("</section><section class=\"cp-settings-section\"><header><div><p class=\"eyebrow\">Security</p><h2>Change password</h2><p>Changing your password signs out every device, including this one.</p></div></header>") catch return mer.internalError("settings render failed");
    if (demo) {
        w.writeAll("<p class=\"cp-settings-readonly\">Password controls are unavailable in the synthetic preview.</p>") catch return mer.internalError("settings render failed");
    } else {
        w.writeAll(
            \\<form method="post" action="/api/settings" data-settings-form data-session-ending data-settings-password-change>
            \\  <input type="hidden" name="action" value="password.change">
            \\  <label class="cp-field cp-password-field"><span>Current password</span><span><input type="password" name="current_password" maxlength="4096" autocomplete="current-password" required><button type="button" data-password-toggle aria-label="Show current password">Show</button></span></label>
            \\  <div data-settings-password-policy>
            \\    <label class="cp-field cp-password-field"><span>New password</span><span><input type="password" name="new_password" minlength="8" maxlength="4096" pattern="(?=.*[A-Z])(?=.*[0-9]).{8,}" title="Use at least 8 characters, including an uppercase letter and a number" autocomplete="new-password" aria-describedby="settings-password-rules" required data-settings-new-password><button type="button" data-password-toggle aria-label="Show new password">Show</button></span></label>
            \\    <ul class="wb-auth-rules cp-settings-password-rules" id="settings-password-rules" aria-label="Password requirements"><li data-settings-password-rule="length"><span aria-hidden="true"></span>8 or more characters</li><li data-settings-password-rule="uppercase"><span aria-hidden="true"></span>One uppercase letter</li><li data-settings-password-rule="number"><span aria-hidden="true"></span>One number</li></ul>
            \\  </div>
            \\  <label class="cp-field cp-password-field"><span class="cp-settings-password-label"><span>Confirm new password</span><small data-settings-password-match aria-live="polite"></small></span><span><input type="password" name="confirm_password" minlength="8" maxlength="4096" autocomplete="new-password" required data-settings-confirm-password><button type="button" data-password-toggle aria-label="Show password confirmation">Show</button></span></label>
            \\  <button class="cp-btn cp-btn-primary" type="submit">Change password</button>
            \\  <p class="cp-form-status" role="status" tabindex="-1"></p>
            \\</form>
        ) catch return mer.internalError("settings render failed");
    }
    w.writeAll("</section>") catch return mer.internalError("settings render failed");
    if (!demo) w.writeAll("<section class=\"cp-settings-section cp-settings-signout\"><div><h2>Sign out this device</h2><p>Your other sessions remain active unless you change your password.</p></div><form action=\"/logout\" method=\"post\"><button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Sign out</button></form></section>") catch return mer.internalError("settings render failed");
    w.writeAll("</div><script src=\"/settings.js?v=20260724\" defer></script>") catch return mer.internalError("settings render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn initial(name: []const u8) u8 {
    return if (name.len > 0) name[0] else 'W';
}
