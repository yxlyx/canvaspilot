// app/callback.zig — receives the JWT app token from the backend OAuth
// callback (which redirects here with ?token=...). Stores it in the
// HttpOnly `cp_session` cookie and sends the user to the dashboard.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Signing you in…",
    .description = "Completing Canvas sign-in.",
};

pub fn render(req: mer.Request) mer.Response {
    if (req.queryParam("error")) |_| {
        return mer.redirect("/login?error=oauth_failed", .see_other);
    }

    const token = req.queryParam("token") orelse {
        return mer.redirect("/login?error=missing_token", .see_other);
    };

    if (token.len == 0) {
        return mer.redirect("/login?error=empty_token", .see_other);
    }

    const cookies = req.allocator.alloc(mer.SetCookie, 1) catch {
        return mer.internalError("could not allocate session cookie");
    };
    cookies[0] = lib.session.setCookie(token);

    return mer.withCookies(mer.redirect("/dashboard", .see_other), cookies);
}
