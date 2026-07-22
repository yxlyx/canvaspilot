// Shared fail-closed guard for every cookie-authenticated browser mutation.
const std = @import("std");
const mer = @import("mer");
const config = @import("config.zig");

const Origin = struct { scheme: []const u8, host: []const u8, port: u16 };
fn defaultPort(scheme: []const u8) u16 {
    return if (std.ascii.eqlIgnoreCase(scheme, "https")) 443 else 80;
}
fn parseAuthority(scheme: []const u8, authority: []const u8) ?Origin {
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "/?#@") != null) return null;
    var host = authority;
    var port = defaultPort(scheme);
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[0 .. close + 1];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':' or close + 2 == authority.len) return null;
            port = std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch return null;
        }
    } else if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority[colon + 1 ..], ':') != null or colon == 0 or colon + 1 == authority.len) return null;
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;
    return .{ .scheme = scheme, .host = host, .port = port };
}
fn parseOrigin(value: []const u8) ?Origin {
    const split = std.mem.indexOf(u8, value, "://") orelse return null;
    const scheme = value[0..split];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
    return parseAuthority(scheme, value[split + 3 ..]);
}
fn sameOrigin(a: Origin, b: Origin) bool {
    return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and std.ascii.eqlIgnoreCase(a.host, b.host) and a.port == b.port;
}
fn loopback(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
}
pub fn allowedForOrigin(req: mer.Request, configured: ?[]const u8) bool {
    if (!std.ascii.eqlIgnoreCase(req.header("sec-fetch-site") orelse "", "same-origin")) return false;
    const supplied = parseOrigin(req.header("origin") orelse return false) orelse return false;
    if (configured) |expected_raw| return sameOrigin(supplied, parseOrigin(expected_raw) orelse return false);
    const host = parseAuthority("http", req.header("host") orelse return false) orelse return false;
    return std.ascii.eqlIgnoreCase(supplied.scheme, "http") and loopback(host.host) and sameOrigin(supplied, host);
}
pub fn guard(req: mer.Request, max_body: usize) ?mer.Response {
    const content_type = req.header("content-type") orelse "";
    const semicolon = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..semicolon], " \t"), "application/json") or
        !allowedForOrigin(req, config.load().public_origin))
        return .{ .status = .forbidden, .content_type = .json, .body = "{\"error\":\"cross-site mutation rejected\"}" };
    if (req.body.len == 0) return mer.badRequest("invalid mutation body size");
    if (req.body.len > max_body) return .{ .status = .payload_too_large, .content_type = .json, .body = "{\"error\":\"request body too large\"}" };
    return null;
}

test "origin comparison normalizes default ports" {
    try std.testing.expect(sameOrigin(parseOrigin("https://study.example").?, parseOrigin("https://study.example:443").?));
    try std.testing.expect(sameOrigin(parseOrigin("http://study.example").?, parseOrigin("http://study.example:80").?));
    try std.testing.expect(!sameOrigin(parseOrigin("http://study.example").?, parseOrigin("http://study.example:81").?));
}

test "mutation guard requires canonical same origin" {
    var req = mer.Request.init(std.testing.allocator, .POST, "/api/m3");
    req.headers = &.{
        .{ .name = "Host", .value = "internal:3001" },
        .{ .name = "Origin", .value = "https://study.example" },
        .{ .name = "Sec-Fetch-Site", .value = "same-origin" },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    try std.testing.expect(allowedForOrigin(req, "https://study.example"));
    try std.testing.expect(allowedForOrigin(req, "https://study.example:443"));
    try std.testing.expect(!allowedForOrigin(req, "https://study.example:444"));
    try std.testing.expect(!allowedForOrigin(req, "https://other.example"));
    try std.testing.expect(!allowedForOrigin(req, null));
}
