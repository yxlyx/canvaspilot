const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

fn redirectError(req: mer.Request, code: []const u8) mer.Response {
    const target = std.fmt.allocPrint(req.allocator, "/login?mode=signup&error={s}", .{code}) catch
        "/login?mode=signup&error=backend_unavailable";
    return mer.redirect(target, .see_other);
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn queryEncode(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn redirectErrorWithValues(req: mer.Request, code: []const u8, name: []const u8, email: []const u8) mer.Response {
    const encoded_name = queryEncode(req.allocator, name) catch return redirectError(req, code);
    const encoded_email = queryEncode(req.allocator, email) catch return redirectError(req, code);
    const target = std.fmt.allocPrint(
        req.allocator,
        "/login?mode=signup&error={s}&name={s}&email={s}",
        .{ code, encoded_name, encoded_email },
    ) catch return redirectError(req, code);
    return mer.redirect(target, .see_other);
}

fn registrationErrorCode(result: anytype) []const u8 {
    const body = result.err orelse "";
    if (std.mem.indexOf(u8, body, "invalid_email") != null) return "invalid_email";
    if (std.mem.indexOf(u8, body, "missing_name") != null) return "missing_fields";
    if (std.mem.indexOf(u8, body, "weak_password") != null) return "weak_password";
    return "backend_unavailable";
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return mer.redirect("/login?mode=signup", .see_other);
    if (!lib.mutation.allowedForOrigin(req, lib.config.load().public_origin)) return .{ .status = .forbidden, .content_type = .text, .body = "cross-site registration rejected" };

    const name = lib.form.value(req.allocator, req.body, "name") catch return redirectError(req, "missing_fields");
    const email = lib.form.value(req.allocator, req.body, "email") catch return redirectError(req, "missing_fields");
    const password = lib.form.value(req.allocator, req.body, "password") catch return redirectError(req, "missing_fields");
    const confirm = lib.form.value(req.allocator, req.body, "confirm_password") catch return redirectError(req, "missing_fields");
    if (name == null or email == null or password == null or confirm == null) {
        return redirectError(req, "missing_fields");
    }
    if (name.?.len == 0 or email.?.len == 0 or password.?.len == 0) {
        return redirectErrorWithValues(req, "missing_fields", name.?, email.?);
    }
    if (!std.mem.eql(u8, password.?, confirm.?)) {
        return redirectErrorWithValues(req, "password_mismatch", name.?, email.?);
    }

    const result = lib.backend.register(req.allocator, name.?, email.?, password.?);
    if (result.value) |v| {
        const cookies = req.allocator.alloc(mer.SetCookie, 2) catch {
            return mer.internalError("could not allocate session cookie");
        };
        cookies[0] = lib.session.setCookie(v.value.token);
        cookies[1] = lib.session.themeCookie("system");
        return mer.withCookies(mer.redirect("/dashboard?auth=registered", .see_other), cookies);
    }

    if (result.status == 409) return redirectErrorWithValues(req, "email_taken", name.?, email.?);
    if (result.status == 400) return redirectErrorWithValues(req, registrationErrorCode(result), name.?, email.?);
    return redirectErrorWithValues(req, "backend_unavailable", name.?, email.?);
}
