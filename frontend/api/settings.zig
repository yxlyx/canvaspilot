const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const Profile = struct { name: []const u8 };
const Password = struct { current_password: []const u8, new_password: []const u8 };
const PasswordOnly = struct { current_password: []const u8 };
const DeleteAccount = struct { current_password: []const u8, confirmation: []const u8 };
const Theme = struct { theme: []const u8 };
const Appearance = struct { theme: []const u8, motion_preference: []const u8 };
const Learning = struct {
    default_module_id: ?[]const u8,
    default_enrollment_id: ?[]const u8,
    daily_review_target: usize,
};
const ReviewTarget = struct { daily_review_target: usize };
const Reminders = struct {
    reminder_daily_review: bool,
    reminder_processing_attention: bool,
    reminder_paper_review: bool,
    reminder_health_attention: bool,
};

fn value(req: mer.Request, name: []const u8) ?[]const u8 {
    return lib.form.value(req.allocator, req.body, name) catch null;
}

fn present(req: mer.Request, name: []const u8) bool {
    return value(req, name) != null;
}

fn stringify(allocator: std.mem.Allocator, payload: anytype) ?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var writer: std.json.Stringify = .{ .writer = &out.writer };
    writer.write(payload) catch return null;
    return out.written();
}

fn mediaType(value_: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, value_, ';') orelse value_.len;
    return std.mem.trim(u8, value_[0..end], " \t");
}

fn archiveDisposition(allocator: std.mem.Allocator, content_type: ?[]const u8, disposition: ?[]const u8, body: []const u8) ?[]const u8 {
    if (!std.ascii.eqlIgnoreCase(mediaType(content_type orelse ""), "application/zip")) return null;
    if (body.len < 4 or body[0] != 'P' or body[1] != 'K' or !((body[2] == 3 and body[3] == 4) or (body[2] == 5 and body[3] == 6) or (body[2] == 7 and body[3] == 8))) return null;
    const raw = disposition orelse return null;
    if (raw.len > 512 or std.mem.indexOfAny(u8, raw, "\r\n") != null) return null;
    var fields = std.mem.splitScalar(u8, raw, ';');
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, fields.first(), " \t"), "attachment")) return null;
    while (fields.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " \t");
        if (trimmed.len < 9 or !std.ascii.eqlIgnoreCase(trimmed[0..9], "filename=")) continue;
        var filename = std.mem.trim(u8, trimmed[9..], " \t");
        if (filename.len >= 2 and filename[0] == '"' and filename[filename.len - 1] == '"') filename = filename[1 .. filename.len - 1];
        if (filename.len == 0 or filename.len > 255) return null;
        for (filename) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return null,
        };
        return std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{filename}) catch null;
    }
    return null;
}

fn safeSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 128) return false;
    for (segment) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn safeUuid(value_: []const u8) bool {
    if (value_.len != 36) return false;
    for (value_, 0..) |c, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const DefaultScope = struct {
    module_id: ?[]const u8 = null,
    enrollment_id: ?[]const u8 = null,
};

fn parseDefaultScope(raw: []const u8) !DefaultScope {
    if (raw.len == 0) return .{};
    const separator = std.mem.indexOfScalar(u8, raw, ':') orelse return error.InvalidScope;
    const kind = raw[0..separator];
    const id = raw[separator + 1 ..];
    if (!safeUuid(id)) return error.InvalidScope;
    if (std.mem.eql(u8, kind, "module")) return .{ .module_id = id };
    if (std.mem.eql(u8, kind, "enrollment")) return .{ .enrollment_id = id };
    return error.InvalidScope;
}

fn wantsJson(req: mer.Request) bool {
    return std.mem.indexOf(u8, req.header("accept") orelse "", "application/json") != null;
}

fn redirectTarget(req: mer.Request, success: bool) mer.Response {
    const raw = value(req, "next") orelse "/settings";
    const target = lib.m3.safeInternalHref(raw, "/settings");
    const separator: []const u8 = if (std.mem.indexOfScalar(u8, target, '?') == null) "?" else "&";
    const location = std.fmt.allocPrint(req.allocator, "{s}{s}{s}=1", .{ target, separator, if (success) "saved" else "error" }) catch target;
    return mer.redirect(location, .see_other);
}

fn reject(req: mer.Request, message: []const u8) mer.Response {
    if (!wantsJson(req)) return redirectTarget(req, false);
    const body = std.fmt.allocPrint(req.allocator, "{{\"error\":\"{s}\"}}", .{message}) catch "{\"error\":\"invalid request\"}";
    return .{ .status = .bad_request, .content_type = .json, .body = body };
}

fn clearSession(req: mer.Request, response: mer.Response) mer.Response {
    const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return response;
    cookies[0] = lib.session.clearCookie();
    return mer.withCookies(response, cookies);
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    if (!lib.mutation.allowedForOrigin(req, lib.config.load().public_origin)) return .{ .status = .forbidden, .content_type = .text, .body = "cross-site mutation rejected" };
    if (!std.ascii.eqlIgnoreCase(mediaType(req.header("content-type") orelse ""), "application/x-www-form-urlencoded") or req.body.len == 0 or req.body.len > 32 * 1024) return reject(req, "invalid form request");
    const action = value(req, "action") orelse return reject(req, "missing action");
    var method: std.http.Method = .POST;
    var path: []const u8 = undefined;
    var payload: ?[]const u8 = null;
    var session_ending = false;
    var download = false;
    var saved_theme: ?[]const u8 = null;
    var saved_motion: ?[]const u8 = null;

    if (std.mem.eql(u8, action, "profile.update")) {
        const name = value(req, "name") orelse return reject(req, "enter a display name");
        if (name.len == 0 or name.len > 255) return reject(req, "enter a display name");
        method = .PATCH;
        path = "/api/account/profile";
        payload = stringify(req.allocator, Profile{ .name = name });
    } else if (std.mem.eql(u8, action, "password.change")) {
        const current = value(req, "current_password") orelse return reject(req, "enter the current password");
        const new_password = value(req, "new_password") orelse return reject(req, "enter a new password");
        const confirm = value(req, "confirm_password") orelse return reject(req, "confirm the new password");
        if (!std.mem.eql(u8, new_password, confirm)) return reject(req, "passwords do not match");
        path = "/api/account/password";
        payload = stringify(req.allocator, Password{ .current_password = current, .new_password = new_password });
        session_ending = true;
    } else if (std.mem.eql(u8, action, "preferences.theme")) {
        const theme = value(req, "theme") orelse return reject(req, "choose a theme");
        if (!std.mem.eql(u8, theme, "light") and !std.mem.eql(u8, theme, "dark")) return reject(req, "choose a valid theme");
        method = .PATCH;
        path = "/api/settings/preferences";
        payload = stringify(req.allocator, Theme{ .theme = theme });
        saved_theme = theme;
    } else if (std.mem.eql(u8, action, "preferences.update")) {
        method = .PATCH;
        path = "/api/settings/preferences";
        if (value(req, "theme")) |theme| {
            if (!std.mem.eql(u8, theme, "system") and !std.mem.eql(u8, theme, "light") and !std.mem.eql(u8, theme, "dark")) return reject(req, "choose a valid theme");
            const motion = value(req, "motion_preference") orelse return reject(req, "choose a motion preference");
            if (!std.mem.eql(u8, motion, "system") and !std.mem.eql(u8, motion, "reduce")) return reject(req, "choose a valid motion preference");
            payload = stringify(req.allocator, Appearance{ .theme = theme, .motion_preference = motion });
            saved_theme = theme;
            saved_motion = motion;
        } else {
            const target_raw = value(req, "daily_review_target") orelse return reject(req, "enter a review target");
            const target = std.fmt.parseInt(usize, target_raw, 10) catch return reject(req, "review target must be a number");
            if (target < 1 or target > 100) return reject(req, "review target must be between 1 and 100");
            if (std.mem.eql(u8, value(req, "scope_loaded") orelse "", "1")) {
                const scope = parseDefaultScope(value(req, "default_scope") orelse "") catch return reject(req, "choose a valid default scope");
                payload = stringify(req.allocator, Learning{ .default_module_id = scope.module_id, .default_enrollment_id = scope.enrollment_id, .daily_review_target = target });
            } else {
                payload = stringify(req.allocator, ReviewTarget{ .daily_review_target = target });
            }
        }
    } else if (std.mem.eql(u8, action, "preferences.notifications")) {
        method = .PATCH;
        path = "/api/settings/preferences";
        payload = stringify(req.allocator, Reminders{ .reminder_daily_review = present(req, "reminder_daily_review"), .reminder_processing_attention = present(req, "reminder_processing_attention"), .reminder_paper_review = present(req, "reminder_paper_review"), .reminder_health_attention = present(req, "reminder_health_attention") });
    } else if (std.mem.eql(u8, action, "account.export")) {
        const current = value(req, "current_password") orelse return reject(req, "enter the current password");
        path = "/api/account/export";
        payload = stringify(req.allocator, PasswordOnly{ .current_password = current });
        download = true;
    } else if (std.mem.eql(u8, action, "account.delete")) {
        const current = value(req, "current_password") orelse return reject(req, "enter the current password");
        const confirmation = value(req, "confirmation") orelse return reject(req, "type DELETE");
        if (!std.mem.eql(u8, confirmation, "DELETE") or !present(req, "final_confirmation")) return reject(req, "complete both confirmations");
        method = .DELETE;
        path = "/api/account";
        payload = stringify(req.allocator, DeleteAccount{ .current_password = current, .confirmation = confirmation });
        session_ending = true;
    } else if (std.mem.eql(u8, action, "notification.read")) {
        const id = value(req, "id") orelse return reject(req, "missing notification");
        if (!safeSegment(id)) return reject(req, "invalid notification");
        path = std.fmt.allocPrint(req.allocator, "/api/notifications/{s}/read", .{id}) catch return reject(req, "invalid notification");
    } else if (std.mem.eql(u8, action, "notifications.read_all")) {
        path = "/api/notifications/read-all";
    } else return reject(req, "unknown action");

    const body: ?[]const u8 = payload orelse if (method.requestHasBody()) @as([]const u8, "null") else null;
    const result = lib.backend.proxy(req.allocator, session.token, "", method, path, body, if (download) 100 * 1024 * 1024 else 2 * 1024 * 1024);
    if (result.status == 0) return if (wantsJson(req)) .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"service unavailable\"}" } else redirectTarget(req, false);
    if (result.status == 401) return clearSession(req, if (wantsJson(req)) .{ .status = .unauthorized, .content_type = .json, .body = result.body } else mer.redirect("/login?reason=session_expired", .see_other));
    if (result.status < 200 or result.status >= 300) return if (wantsJson(req)) .{ .status = @enumFromInt(result.status), .content_type = .json, .body = result.body } else redirectTarget(req, false);
    if (download) {
        const disposition = archiveDisposition(req.allocator, result.content_type, result.content_disposition, result.body) orelse return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"invalid account archive response\"}" };
        const headers = req.allocator.alloc(std.http.Header, 2) catch return mer.internalError("download headers failed");
        headers[0] = .{ .name = "content-disposition", .value = disposition };
        headers[1] = .{ .name = "x-content-type-options", .value = "nosniff" };
        return .{ .status = .ok, .content_type = .zip, .body = result.body, .headers = headers };
    }
    if (session_ending) return clearSession(req, if (wantsJson(req)) .{ .status = .ok, .content_type = .json, .body = "{\"ok\":true,\"redirect\":\"/login\"}" } else mer.redirect("/login?reason=account_changed", .see_other));
    var response: mer.Response = if (wantsJson(req))
        .{ .status = .ok, .content_type = .json, .body = if (result.body.len > 0) result.body else "{\"ok\":true}" }
    else
        redirectTarget(req, true);
    const cookie_count: usize = @intFromBool(saved_theme != null) + @intFromBool(saved_motion != null);
    if (cookie_count > 0) {
        const cookies = req.allocator.alloc(mer.SetCookie, cookie_count) catch return response;
        var index: usize = 0;
        if (saved_theme) |theme| {
            cookies[index] = lib.session.themeCookie(theme);
            index += 1;
        }
        if (saved_motion) |motion| cookies[index] = lib.session.motionCookie(motion);
        response = mer.withCookies(response, cookies);
    }
    return response;
}

test "account archives require ZIP content and an attachment filename" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("attachment; filename=\"wikibase-account.zip\"", archiveDisposition(allocator, "application/zip; charset=binary", "attachment; filename=wikibase-account.zip", "PK\x05\x06empty").?);
    try std.testing.expect(archiveDisposition(allocator, "text/html", "attachment; filename=wikibase-account.zip", "<html>login</html>") == null);
    try std.testing.expect(archiveDisposition(allocator, "application/zip", null, "PK\x03\x04archive") == null);
    try std.testing.expect(archiveDisposition(allocator, "application/zip", "inline; filename=wikibase-account.zip", "PK\x03\x04archive") == null);
}

test "default learning scopes preserve their identity type" {
    const enrollment = try parseDefaultScope("enrollment:123e4567-e89b-12d3-a456-426614174000");
    try std.testing.expect(enrollment.module_id == null);
    try std.testing.expectEqualStrings("123e4567-e89b-12d3-a456-426614174000", enrollment.enrollment_id.?);
    const module = try parseDefaultScope("module:223e4567-e89b-12d3-a456-426614174000");
    try std.testing.expect(module.enrollment_id == null);
    try std.testing.expectEqualStrings("223e4567-e89b-12d3-a456-426614174000", module.module_id.?);
    try std.testing.expectError(error.InvalidScope, parseDefaultScope("../module-enrollments"));
}
