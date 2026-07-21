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

pub fn liveError(req: mer.Request, feature: []const u8, status: u16) mer.Response {
    if (status == 401) {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("session clear failed");
        cookies[0] = session.clearCookie();
        return mer.withCookies(mer.redirect("/login", .see_other), cookies);
    }
    var buf = ui.buildHtml(req.allocator);
    const safe_feature = ui.escapeSafe(req.allocator, feature);
    buf.writer.print(
        "<header class=\"cp-page-header\"><div><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">Live workspace</p></div></header><section class=\"cp-card cp-unavailable\" role=\"alert\"><h2>Service unavailable</h2><p>WikiBase could not load this live data (backend status {d}). No demo data has been substituted.</p><a class=\"cp-btn cp-btn-ghost\" href=\"\">Try again</a></section>",
        .{ safe_feature, status },
    ) catch return mer.internalError("M3 error state failed");
    return ui.htmlResponse(&buf);
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
