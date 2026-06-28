// app/logout.zig — clears the session cookie and redirects to /login.
// Accepts both GET (link) and POST (form) so the header sign-out form
// works without JS.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Signed out",
    .description = "You've been signed out of WikiBase.",
};

pub fn render(req: mer.Request) mer.Response {
    const cookies = req.allocator.alloc(mer.SetCookie, 1) catch {
        return mer.internalError("could not clear session cookie");
    };
    cookies[0] = lib.session.clearCookie();
    return mer.withCookies(mer.redirect("/login?signed_out=1", .see_other), cookies);
}
