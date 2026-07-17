// src/lib/m3.zig — shared Milestone 3 access and safety helpers.
// Fixture data is available only when the server opt-in and request opt-in
// are both present. New M3 pages never use fixtures as a live fallback.

const std = @import("std");
const mer = @import("mer");
const config = @import("config.zig");
const session = @import("session.zig");
const ui = @import("ui.zig");

pub const Access = enum { demo, unavailable, login };

pub fn accessFor(mock_enabled: bool, requested_mock: ?[]const u8, authenticated: bool) Access {
    if (mock_enabled and requested_mock != null and std.mem.eql(u8, requested_mock.?, "1")) return .demo;
    return if (authenticated) .unavailable else .login;
}

pub fn isExplicitDemo(req: mer.Request) bool {
    return accessFor(config.load().mock_enabled, req.queryParam("mock"), session.fromRequest(req).isAuthenticated()) == .demo;
}

pub fn access(req: mer.Request) Access {
    return accessFor(config.load().mock_enabled, req.queryParam("mock"), session.fromRequest(req).isAuthenticated());
}

pub fn gate(req: mer.Request, feature: []const u8) ?mer.Response {
    switch (access(req)) {
        .demo => return null,
        .login => return mer.redirect("/login", .see_other),
        .unavailable => {},
    }

    var buf = ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const safe_feature = ui.escapeSafe(req.allocator, feature);
    w.print(
        \\<header class="cp-page-header"><div><h1 class="cp-page-title">{s}</h1>
        \\<p class="cp-page-sub">Signed in, but live Milestone 3 data is unavailable.</p></div></header>
        \\<section class="cp-card cp-unavailable" aria-labelledby="m3-unavailable-title">
        \\  <div class="cp-demo-label cp-live-label">Live unavailable</div>
        \\  <h2 id="m3-unavailable-title">Backend contract not implemented</h2>
        \\  <p>This frontend does not substitute demo fixtures for your live workspace. The controls remain unavailable until the corresponding backend endpoint is delivered.</p>
        \\  <a class="cp-btn cp-btn-ghost" href="/dashboard">Return to workspace</a>
        \\</section>
    , .{safe_feature}) catch return mer.internalError("M3 unavailable state failed");
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
