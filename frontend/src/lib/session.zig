// src/lib/session.zig — cookie-based session helpers. The backend issues a
// JWT in `?token=` on the OAuth redirect; `/callback` stores it as an
// HttpOnly cookie called `cp_session` (name configurable in lib/config.zig).

const std = @import("std");
const mer = @import("mer");
const config = @import("config.zig");

pub const Session = struct {
    /// JWT app token. Empty string when the user is signed out.
    token: []const u8,

    pub fn isAuthenticated(self: Session) bool {
        return self.token.len > 0;
    }
};

/// Read the session token cookie off the request, or return an empty session.
pub fn fromRequest(req: mer.Request) Session {
    const cfg = config.load();
    if (req.cookie(cfg.session_cookie)) |value| {
        return .{ .token = value };
    }
    return .{ .token = "" };
}

/// Build a Set-Cookie that stores the given JWT for one week.
pub fn setCookie(token: []const u8) mer.SetCookie {
    const cfg = config.load();
    return .{
        .name = cfg.session_cookie,
        .value = token,
        .path = "/",
        .max_age = 7 * 24 * 3600,
        .http_only = true,
        .secure = false,
        .same_site = .lax,
    };
}

/// Build a Set-Cookie that immediately clears the session cookie.
pub fn clearCookie() mer.SetCookie {
    const cfg = config.load();
    return .{
        .name = cfg.session_cookie,
        .value = "",
        .path = "/",
        .max_age = 0,
        .http_only = true,
        .secure = false,
        .same_site = .lax,
    };
}

/// Redirect anonymous users to /login. Page handlers wrap their work in
/// `if (session.requireAuth(req)) |redirect| return redirect;` to gate
/// dashboard/chat routes.
pub fn requireAuth(req: mer.Request) ?mer.Response {
    const s = fromRequest(req);
    if (!s.isAuthenticated()) {
        return mer.redirect("/login", .see_other);
    }
    return null;
}
