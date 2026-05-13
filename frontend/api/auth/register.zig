const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

fn redirectError(req: mer.Request, code: []const u8) mer.Response {
    const target = std.fmt.allocPrint(req.allocator, "/login?mode=signup&error={s}", .{code}) catch
        "/login?mode=signup&error=backend_unavailable";
    return mer.redirect(target, .see_other);
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return mer.redirect("/login?mode=signup", .see_other);

    const name = lib.form.value(req.allocator, req.body, "name") catch return redirectError(req, "missing_fields");
    const email = lib.form.value(req.allocator, req.body, "email") catch return redirectError(req, "missing_fields");
    const password = lib.form.value(req.allocator, req.body, "password") catch return redirectError(req, "missing_fields");
    const confirm = lib.form.value(req.allocator, req.body, "confirm_password") catch return redirectError(req, "missing_fields");
    if (name == null or email == null or password == null or confirm == null) {
        return redirectError(req, "missing_fields");
    }
    if (name.?.len == 0 or email.?.len == 0 or password.?.len == 0) {
        return redirectError(req, "missing_fields");
    }
    if (!std.mem.eql(u8, password.?, confirm.?)) {
        return redirectError(req, "password_mismatch");
    }

    const result = lib.backend.register(req.allocator, name.?, email.?, password.?);
    if (result.value) |v| {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch {
            return mer.internalError("could not allocate session cookie");
        };
        cookies[0] = lib.session.setCookie(v.value.token);
        return mer.withCookies(mer.redirect("/dashboard?mock=1&auth=registered", .see_other), cookies);
    }

    if (result.status == 409) return redirectError(req, "email_taken");
    if (result.status == 400) return redirectError(req, "weak_password");
    return redirectError(req, "backend_unavailable");
}
