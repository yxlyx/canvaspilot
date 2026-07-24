// src/lib/m3.zig — shared Milestone 3 access and safety helpers.
// Fixture data is available only when the server opt-in and request opt-in
// are both present. New M3 pages never use fixtures as a live fallback.

const std = @import("std");
const mer = @import("mer");
const config = @import("config.zig");
const session = @import("session.zig");
const ui = @import("ui.zig");

pub const Access = enum { demo, live, login };

pub fn accessFor(mock_enabled: bool, requested_mock: ?[]const u8, authenticated: bool) Access {
    if (mock_enabled and requested_mock != null and std.mem.eql(u8, requested_mock.?, "1")) return .demo;
    return if (authenticated) .live else .login;
}

pub fn isExplicitDemo(req: mer.Request) bool {
    return accessFor(config.load().mock_enabled, req.queryParam("mock"), session.fromRequest(req).isAuthenticated()) == .demo;
}

pub fn access(req: mer.Request) Access {
    return accessFor(config.load().mock_enabled, req.queryParam("mock"), session.fromRequest(req).isAuthenticated());
}

pub fn gate(req: mer.Request, feature: []const u8) ?mer.Response {
    _ = feature;
    return if (access(req) == .login) mer.redirect("/login", .see_other) else null;
}

fn privateIp4(address: std.Io.net.Ip4Address) bool {
    const b = address.bytes;
    return b[0] == 0 or
        b[0] == 10 or
        b[0] == 127 or
        (b[0] == 100 and b[1] >= 64 and b[1] <= 127) or
        (b[0] == 169 and b[1] == 254) or
        (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
        (b[0] == 192 and b[1] == 168) or
        b[0] >= 224;
}

fn privateIp6(address: std.Io.net.Ip6Address) bool {
    const b = address.bytes;
    const unspecified = std.mem.allEqual(u8, &b, 0);
    const loopback = std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1;
    if (unspecified or loopback or (b[0] & 0xfe) == 0xfc or (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) or b[0] == 0xff) return true;
    if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) {
        return privateIp4(.{ .bytes = b[12..16].*, .port = 0 });
    }
    return false;
}

fn validPort(raw: []const u8) bool {
    if (raw.len == 0) return false;
    return (std.fmt.parseInt(u16, raw, 10) catch return false) != 0;
}

fn privateHostname(host: []const u8) bool {
    const private_suffixes = [_][]const u8{ "localhost", "local", "internal", "lan", "home" };
    for (private_suffixes) |suffix| {
        if (std.ascii.eqlIgnoreCase(host, suffix)) return true;
        if (host.len > suffix.len and host[host.len - suffix.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix)) return true;
    }
    return false;
}

fn validPublicHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253 or privateHostname(host)) return false;
    if (std.Io.net.Ip4Address.parse(host, 0)) |address| return !privateIp4(address) else |_| {}

    var numeric = true;
    for (host) |c| if (c != '.' and (c < '0' or c > '9')) {
        numeric = false;
        break;
    };
    // Browsers accept ambiguous integer and shortened IPv4 forms. Reject all
    // numeric-looking hosts unless they parsed as canonical dotted decimal.
    if (numeric or std.mem.indexOfScalar(u8, host, '.') == null) return false;

    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// Accept only local application paths and well-formed public HTTP(S) URLs.
/// Literal private addresses and conventional private hostnames are rendered
/// as a fallback instead of a browser-reachable local-network link.
pub fn safeSourceHref(raw: []const u8, fallback: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, raw, " \t\r\n\\") != null) return fallback;
    if (std.mem.startsWith(u8, raw, "/")) return if (!std.mem.startsWith(u8, raw, "//")) raw else fallback;

    const scheme_end = std.mem.indexOfScalar(u8, raw, ':') orelse return fallback;
    const scheme = raw[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return fallback;
    if (scheme_end + 3 > raw.len or !std.mem.eql(u8, raw[scheme_end + 1 .. scheme_end + 3], "//")) return fallback;
    const authority_start = scheme_end + 3;
    const authority_end = std.mem.indexOfAnyPos(u8, raw, authority_start, "/?#") orelse raw.len;
    const authority = raw[authority_start..authority_end];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "@%") != null) return fallback;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return fallback;
        if (close + 1 < authority.len and (authority[close + 1] != ':' or !validPort(authority[close + 2 ..]))) return fallback;
        const address = std.Io.net.Ip6Address.parse(authority[1..close], 0) catch return fallback;
        return if (!privateIp6(address)) raw else fallback;
    }

    var host = authority;
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority[colon + 1 ..], ':') != null or !validPort(authority[colon + 1 ..])) return fallback;
        host = authority[0..colon];
    }
    return if (validPublicHost(host)) raw else fallback;
}

/// Prevent authenticated and explicit-demo responses from entering shared or
/// browser caches. Request allocators outlive response serialization.
pub fn privateForSession(req: mer.Request, response: mer.Response) mer.Response {
    if (!session.fromRequest(req).isAuthenticated() and !isExplicitDemo(req)) return response;
    const headers = req.allocator.alloc(std.http.Header, response.headers.len + 2) catch
        return mer.internalError("private response headers failed");
    @memcpy(headers[0..response.headers.len], response.headers);
    headers[response.headers.len] = .{ .name = "Cache-Control", .value = "private, no-store" };
    headers[response.headers.len + 1] = .{ .name = "Vary", .value = "Cookie" };
    var private = response;
    private.headers = headers;
    return private;
}

pub fn liveError(req: mer.Request, feature: []const u8, status: u16) mer.Response {
    if (status == 401) {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("session clear failed");
        cookies[0] = session.clearCookie();
        return privateForSession(req, mer.withCookies(mer.redirect("/login", .see_other), cookies));
    }
    var buf = ui.buildHtml(req.allocator);
    const safe_feature = ui.escapeSafe(req.allocator, feature);
    buf.writer.print(
        "<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Live workspace</p></div></header><section class=\"cp-card cp-unavailable\" role=\"alert\"><h2>Service unavailable</h2><p>WikiBase could not load this live data (backend status {d}). No demo data has been substituted.</p><a class=\"cp-btn cp-btn-ghost\" href=\"\">Try again</a></section>",
        .{ safe_feature, status },
    ) catch return mer.internalError("M3 error state failed");
    var response = ui.htmlResponse(&buf);
    response.status = if (status >= 400 and status <= 599) @enumFromInt(status) else .bad_gateway;
    return privateForSession(req, response);
}

pub fn demoMarker(req: mer.Request, w: *std.Io.Writer) !void {
    if (!isExplicitDemo(req)) return;
    if (session.fromRequest(req).isAuthenticated()) {
        try w.writeAll("<span hidden data-cp-demo=\"true\"></span>");
    } else {
        try w.writeAll("<span hidden data-cp-auth=\"anonymous\" data-cp-demo=\"true\"></span>");
    }
}

pub fn demoBanner(req: mer.Request, w: *std.Io.Writer) !void {
    if (!isExplicitDemo(req)) return;
    try demoMarker(req, w);
    try w.writeAll("<div class=\"cp-demo-label\" role=\"status\">Demo data · synthetic fixtures, not live workspace data</div>\n");
}

/// Return an allocator-owned link with exactly one explicit-demo query marker.
pub fn demoHrefFor(allocator: std.mem.Allocator, explicit_demo: bool, path: []const u8) ![]const u8 {
    if (!explicit_demo) return allocator.dupe(u8, path);

    const fragment_index = std.mem.indexOfScalar(u8, path, '#') orelse path.len;
    const base = path[0..fragment_index];
    const fragment = path[fragment_index..];
    const query_index = std.mem.indexOfScalar(u8, base, '?');
    const route = if (query_index) |index| base[0..index] else base;
    const query = if (query_index) |index| base[index + 1 ..] else "";

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(route);
    try out.writer.writeByte('?');

    var wrote_field = false;
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const equals_index = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
        if (std.mem.eql(u8, field[0..equals_index], "mock")) continue;
        if (wrote_field) try out.writer.writeByte('&');
        try out.writer.writeAll(field);
        wrote_field = true;
    }
    if (wrote_field) try out.writer.writeByte('&');
    try out.writer.writeAll("mock=1");
    try out.writer.writeAll(fragment);
    return out.toOwnedSlice();
}

pub fn demoHref(allocator: std.mem.Allocator, req: mer.Request, path: []const u8) ![]const u8 {
    return demoHrefFor(allocator, isExplicitDemo(req), path);
}

pub fn safeInternalHref(raw: []const u8, fallback: []const u8) []const u8 {
    if (raw.len == 0 or raw[0] != '/' or std.mem.startsWith(u8, raw, "//")) return fallback;
    for (raw) |c| {
        if (c <= 0x20 or c == 0x7f or c == '\\') return fallback;
    }
    return raw;
}

pub fn pageOffset(raw: ?[]const u8, page_size: usize) usize {
    const page = std.fmt.parseInt(usize, raw orelse "1", 10) catch return 0;
    if (page < 1) return 0;
    return std.math.mul(usize, page - 1, page_size) catch 0;
}

pub fn safeId(raw: []const u8, fallback: []const u8) []const u8 {
    if (raw.len == 0 or raw.len > 128) return fallback;
    for (raw) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return fallback,
    };
    return raw;
}

pub fn safeExportFilename(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var last_dash = false;
    for (title) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            try out.writer.writeByte(lower);
            last_dash = false;
        } else if (!last_dash and out.written().len > 0) {
            try out.writer.writeByte('-');
            last_dash = true;
        }
    }
    var stem: []const u8 = out.written();
    while (stem.len > 0 and stem[stem.len - 1] == '-') stem = stem[0 .. stem.len - 1];
    if (stem.len == 0) stem = "wikibase-export";
    return std.fmt.allocPrint(allocator, "{s}.md", .{stem});
}

pub fn meterValue(estimate: anytype) ?u8 {
    const value = estimate orelse return null;
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => if (value <= 100) @intCast(value) else null,
        .float, .comptime_float => if (std.math.isFinite(value) and value >= 0 and value <= 1) @intFromFloat(@round(value * 100)) else null,
        else => null,
    };
}

pub fn meterPercent(estimate: ?f64) ?u8 {
    const value = estimate orelse return null;
    return if (std.math.isFinite(value) and value >= 0 and value <= 100)
        @intFromFloat(@round(value))
    else
        null;
}

test "demo access requires both server opt-in and exact request value" {
    try std.testing.expectEqual(Access.live, accessFor(false, "1", true));
    try std.testing.expectEqual(Access.live, accessFor(true, "true", true));
    try std.testing.expectEqual(Access.live, accessFor(true, "", true));
    try std.testing.expectEqual(Access.demo, accessFor(true, "1", true));
    try std.testing.expectEqual(Access.demo, accessFor(true, "1", false));
    try std.testing.expectEqual(Access.login, accessFor(true, null, false));
}

test "demo links retain one exact mock marker" {
    const allocator = std.testing.allocator;
    const href = try demoHrefFor(allocator, true, "/sources?status=ready&mock=other#queue");
    defer allocator.free(href);
    try std.testing.expectEqualStrings("/sources?status=ready&mock=1#queue", href);

    const live_href = try demoHrefFor(allocator, false, "/sources?status=ready");
    defer allocator.free(live_href);
    try std.testing.expectEqualStrings("/sources?status=ready", live_href);
}

test "source links reject private network and malformed destinations" {
    const fallback = "/sources";
    try std.testing.expectEqualStrings("/chat", safeSourceHref("/chat", fallback));
    try std.testing.expectEqualStrings("https://canvas.example.edu/courses/1", safeSourceHref("https://canvas.example.edu/courses/1", fallback));
    try std.testing.expectEqualStrings("HTTPS://canvas.example.edu/courses/1", safeSourceHref("HTTPS://canvas.example.edu/courses/1", fallback));
    try std.testing.expectEqualStrings("http://8.8.8.8/source", safeSourceHref("http://8.8.8.8/source", fallback));
    try std.testing.expectEqualStrings("https://[2606:4700:4700::1111]/source", safeSourceHref("https://[2606:4700:4700::1111]/source", fallback));

    const rejected = [_][]const u8{
        "//127.0.0.1/source",
        "javascript:alert(1)",
        "https://user@example.edu/source",
        "http://localhost/source",
        "http://service.internal/source",
        "http://127.0.0.1/source",
        "http://10.0.0.1/source",
        "http://169.254.169.254/latest/meta-data",
        "http://172.16.0.1/source",
        "http://192.168.1.1/source",
        "http://2130706433/source",
        "http://[::1]/source",
        "http://[fe80::1]/source",
        "http://[fc00::1]/source",
    };
    for (rejected) |href| try std.testing.expectEqualStrings(fallback, safeSourceHref(href, fallback));
}

test "authenticated responses are private and vary on the session cookie" {
    const allocator = std.testing.allocator;
    const cookie = try std.fmt.allocPrint(allocator, "{s}=test-token", .{config.load().session_cookie});
    defer allocator.free(cookie);
    var req = mer.Request.init(allocator, .GET, "/dashboard");
    req.cookies_raw = cookie;
    const response = privateForSession(req, mer.html("private"));
    defer allocator.free(response.headers);

    try std.testing.expectEqual(@as(usize, 2), response.headers.len);
    try std.testing.expectEqualStrings("Cache-Control", response.headers[0].name);
    try std.testing.expectEqualStrings("private, no-store", response.headers[0].value);
    try std.testing.expectEqualStrings("Vary", response.headers[1].name);
    try std.testing.expectEqualStrings("Cookie", response.headers[1].value);

    const anonymous = privateForSession(mer.Request.init(allocator, .GET, "/dashboard"), mer.html("public"));
    try std.testing.expectEqual(@as(usize, 0), anonymous.headers.len);
}
