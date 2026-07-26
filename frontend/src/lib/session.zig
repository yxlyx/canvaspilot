// src/lib/session.zig — cookie-based session helpers. The frontend auth
// handlers store the backend-issued JWT in an HttpOnly cookie called
// `cp_session` (name configurable in lib/config.zig).

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

fn isLoopbackHttp(origin: []const u8) bool {
    if (!std.mem.startsWith(u8, origin, "http://")) return false;
    const authority = origin[7..];
    const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    const host_port = authority[0..end];
    if (std.mem.startsWith(u8, host_port, "[::1]")) return host_port.len == 5 or host_port[5] == ':';
    const colon = std.mem.indexOfScalar(u8, host_port, ':') orelse host_port.len;
    const host = host_port[0..colon];
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
}

pub fn secureForOrigin(origin: ?[]const u8) bool {
    return if (origin) |value| !isLoopbackHttp(value) else true;
}

fn buildCookie(name: []const u8, value: []const u8, max_age: u32, origin: ?[]const u8) mer.SetCookie {
    return .{
        .name = name,
        .value = value,
        .path = "/",
        .max_age = max_age,
        .http_only = true,
        .secure = secureForOrigin(origin),
        .same_site = .lax,
    };
}

/// Build a Set-Cookie that stores the given JWT for one week.
pub fn setCookie(token: []const u8) mer.SetCookie {
    const cfg = config.load();
    return buildCookie(cfg.session_cookie, token, 7 * 24 * 3600, cfg.public_origin);
}

/// Build a Set-Cookie that immediately clears the session cookie.
pub fn clearCookie() mer.SetCookie {
    const cfg = config.load();
    return buildCookie(cfg.session_cookie, "", 0, cfg.public_origin);
}

pub fn providerAuthCookie(allocator: std.mem.Allocator, session_id: []const u8, value: []const u8) !mer.SetCookie {
    const cfg = config.load();
    const name = try std.fmt.allocPrint(allocator, "cp_provider_auth_{s}", .{session_id});
    var cookie = buildCookie(name, value, 10 * 60, cfg.public_origin);
    cookie.path = "/api/providers/chatgpt/oauth/callback";
    return cookie;
}

pub fn clearProviderAuthCookie(allocator: std.mem.Allocator, session_id: []const u8) !mer.SetCookie {
    const cfg = config.load();
    const name = try std.fmt.allocPrint(allocator, "cp_provider_auth_{s}", .{session_id});
    var cookie = buildCookie(name, "", 0, cfg.public_origin);
    cookie.path = "/api/providers/chatgpt/oauth/callback";
    return cookie;
}

pub fn themeCookie(preference: []const u8) mer.SetCookie {
    const cfg = config.load();
    const safe = if (std.mem.eql(u8, preference, "light") or std.mem.eql(u8, preference, "dark") or std.mem.eql(u8, preference, "system")) preference else "system";
    var cookie = buildCookie("wb_theme_preference", safe, 365 * 24 * 3600, cfg.public_origin);
    cookie.http_only = false;
    return cookie;
}

pub fn motionCookie(preference: []const u8) mer.SetCookie {
    const cfg = config.load();
    const safe = if (std.mem.eql(u8, preference, "reduce")) preference else "system";
    var cookie = buildCookie("wb_motion_preference", safe, 365 * 24 * 3600, cfg.public_origin);
    cookie.http_only = false;
    return cookie;
}

test "provider authorization cookies are isolated by session" {
    const first = try providerAuthCookie(std.testing.allocator, "11111111-1111-4111-8111-111111111111", "binding-one");
    defer std.testing.allocator.free(first.name);
    const second = try providerAuthCookie(std.testing.allocator, "22222222-2222-4222-8222-222222222222", "binding-two");
    defer std.testing.allocator.free(second.name);
    try std.testing.expect(!std.mem.eql(u8, first.name, second.name));
    try std.testing.expectEqualStrings("/api/providers/chatgpt/oauth/callback", first.path);
    try std.testing.expect(first.http_only);
}

test "session cookies fail secure except explicit loopback HTTP" {
    try std.testing.expect(secureForOrigin(null));
    try std.testing.expect(secureForOrigin("https://study.example"));
    try std.testing.expect(secureForOrigin("http://study.example"));
    try std.testing.expect(!secureForOrigin("http://127.0.0.1:3000"));
    try std.testing.expect(!secureForOrigin("http://localhost:3000"));

    var buffer: [256]u8 = undefined;
    const deployed = buildCookie("cp_session", "token", 3600, "https://study.example").headerValue(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, deployed, "; Max-Age=3600") != null);
    try std.testing.expect(std.mem.indexOf(u8, deployed, "; HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, deployed, "; Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, deployed, "; SameSite=Lax") != null);

    var loopback_buffer: [256]u8 = undefined;
    const loopback = buildCookie("cp_session", "token", 3600, "http://127.0.0.1:3000").headerValue(&loopback_buffer);
    try std.testing.expect(std.mem.indexOf(u8, loopback, "; Secure") == null);

    var theme_buffer: [256]u8 = undefined;
    const theme = themeCookie("dark").headerValue(&theme_buffer);
    try std.testing.expect(std.mem.indexOf(u8, theme, "wb_theme_preference=dark") != null);
    try std.testing.expect(std.mem.indexOf(u8, theme, "; HttpOnly") == null);

    var motion_buffer: [256]u8 = undefined;
    const motion = motionCookie("reduce").headerValue(&motion_buffer);
    try std.testing.expect(std.mem.indexOf(u8, motion, "wb_motion_preference=reduce") != null);
    try std.testing.expect(std.mem.indexOf(u8, motion, "; HttpOnly") == null);
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
