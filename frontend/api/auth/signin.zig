const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

fn redirectError(req: mer.Request, code: []const u8) mer.Response {
    const target = std.fmt.allocPrint(req.allocator, "/login?mode=signin&error={s}", .{code}) catch
        "/login?mode=signin&error=backend_unavailable";
    return mer.redirect(target, .see_other);
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return mer.redirect("/login?mode=signin", .see_other);
    if (!lib.mutation.allowedForOrigin(req, lib.config.load().public_origin)) return .{ .status = .forbidden, .content_type = .text, .body = "cross-site sign-in rejected" };

    const email = lib.form.value(req.allocator, req.body, "email") catch return redirectError(req, "missing_fields");
    const password = lib.form.value(req.allocator, req.body, "password") catch return redirectError(req, "missing_fields");
    if (email == null or password == null or email.?.len == 0 or password.?.len == 0) {
        return redirectError(req, "missing_fields");
    }

    const result = lib.backend.login(req.allocator, email.?, password.?);
    if (result.value) |v| {
        const cookies = req.allocator.alloc(mer.SetCookie, 3) catch {
            return mer.internalError("could not allocate session cookie");
        };
        cookies[0] = lib.session.setCookie(v.value.token);
        const preferences = lib.backend.preferences(req.allocator, v.value.token);
        cookies[1] = lib.session.themeCookie(if (preferences.value) |parsed| parsed.value.theme else "system");
        cookies[2] = lib.session.motionCookie(if (preferences.value) |parsed| parsed.value.motion_preference else "system");
        return mer.withCookies(mer.redirect("/dashboard?auth=signed_in", .see_other), cookies);
    }

    if (result.status == 401) return redirectError(req, "invalid_credentials");
    return redirectError(req, "backend_unavailable");
}
