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

    const email = lib.form.value(req.allocator, req.body, "email") catch return redirectError(req, "missing_fields");
    const password = lib.form.value(req.allocator, req.body, "password") catch return redirectError(req, "missing_fields");
    if (email == null or password == null or email.?.len == 0 or password.?.len == 0) {
        return redirectError(req, "missing_fields");
    }

    const result = lib.backend.login(req.allocator, email.?, password.?);
    if (result.value) |v| {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch {
            return mer.internalError("could not allocate session cookie");
        };
        cookies[0] = lib.session.setCookie(v.value.token);
        return mer.withCookies(mer.redirect("/dashboard?mock=1&auth=signed_in", .see_other), cookies);
    }

    if (result.status == 401) return redirectError(req, "invalid_credentials");
    return redirectError(req, "backend_unavailable");
}
