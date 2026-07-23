const std = @import("std");
const mer = @import("mer");
const navigation = @import("navigation.zig");

pub fn heading(req: mer.Request, w: *std.Io.Writer, active: []const u8, kicker: []const u8, title: []const u8, description: []const u8, demo: bool) !void {
    try w.print("<header class=\"cp-page-header cp-settings-heading\"><div><p class=\"cp-page-kicker\">{s}</p><h1 class=\"cp-page-title\">{s}</h1><p class=\"cp-page-sub\">{s}</p></div></header>", .{ kicker, title, description });
    try navigation.renderTabs(req.allocator, w, &navigation.settings_tabs, active, "Settings", demo);
    if (req.queryParam("saved")) |_| try w.writeAll("<div class=\"cp-settings-notice\" role=\"status\">Your settings were saved.</div>");
    if (req.queryParam("error")) |_| try w.writeAll("<div class=\"cp-settings-notice cp-settings-notice-error\" role=\"alert\">That change could not be saved. Review the form and try again.</div>");
}

pub fn selected(actual: []const u8, expected: []const u8) []const u8 {
    return if (std.mem.eql(u8, actual, expected)) " selected" else "";
}

pub fn checked(value: bool) []const u8 {
    return if (value) " checked" else "";
}
