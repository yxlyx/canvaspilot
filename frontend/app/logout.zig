// app/logout.zig — clears the session cookie and redirects to /login.
// POST-only and canonical-origin guarded so another site cannot clear a session.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Signed out",
    .description = "You've been signed out of WikiBase.",
};

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    if (!lib.mutation.allowedForOrigin(req, lib.config.load().public_origin)) return .{ .status = .forbidden, .content_type = .text, .body = "cross-site sign-out rejected" };
    const cookies = req.allocator.alloc(mer.SetCookie, 1) catch {
        return mer.internalError("could not clear session cookie");
    };
    cookies[0] = lib.session.clearCookie();
    return mer.withCookies(mer.redirect("/login?signed_out=1", .see_other), cookies);
}
