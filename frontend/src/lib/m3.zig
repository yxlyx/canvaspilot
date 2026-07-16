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
    const safe_feature = ui.escape(req.allocator, feature) catch feature;
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

pub fn demoBanner(w: *std.Io.Writer) !void {
    try w.writeAll("<span hidden data-cp-auth=\"anonymous\" data-cp-demo=\"true\"></span><div class=\"cp-demo-label\" role=\"status\">Demo data · synthetic fixtures, not live workspace data</div>\n");
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

pub fn meterValue(estimate: ?u8) ?u8 {
    return estimate;
}
