const std = @import("std");
const mer = @import("mer");
const m3 = @import("m3.zig");

pub const Tab = struct {
    href: []const u8,
    label: []const u8,
    id: []const u8,
};

pub const source_tabs = [_]Tab{
    .{ .href = "/sources", .label = "Library", .id = "library" },
    .{ .href = "/sources/health", .label = "Health", .id = "health" },
    .{ .href = "/sources/papers", .label = "Papers", .id = "papers" },
};

pub const wiki_tabs = [_]Tab{
    .{ .href = "/wiki", .label = "Articles", .id = "articles" },
    .{ .href = "/wiki/knowledge", .label = "Knowledge", .id = "knowledge" },
    .{ .href = "/wiki/activity", .label = "Activity", .id = "activity" },
    .{ .href = "/wiki/guides", .label = "Study guides", .id = "guides" },
};

pub const settings_tabs = [_]Tab{
    .{ .href = "/settings", .label = "Account", .id = "account" },
    .{ .href = "/settings/appearance", .label = "Appearance", .id = "appearance" },
    .{ .href = "/settings/learning", .label = "Learning", .id = "learning" },
    .{ .href = "/settings/notifications", .label = "Notifications", .id = "notifications" },
    .{ .href = "/settings/providers", .label = "AI providers", .id = "providers" },
    .{ .href = "/settings/data", .label = "Data & privacy", .id = "data" },
};

pub fn renderTabs(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    tabs: []const Tab,
    active: []const u8,
    label: []const u8,
    explicit_demo: bool,
) !void {
    try w.print("<nav class=\"cp-local-tabs\" aria-label=\"{s}\"><div>", .{label});
    for (tabs) |tab| {
        const href = try m3.demoHrefFor(allocator, explicit_demo, tab.href);
        const current: []const u8 = if (std.mem.eql(u8, active, tab.id))
            " aria-current=\"page\""
        else
            "";
        try w.print("<a href=\"{s}\"{s}>{s}</a>", .{ href, current, tab.label });
    }
    try w.writeAll("</div></nav>");
}

pub fn redirectPreservingQuery(req: mer.Request, destination: []const u8) mer.Response {
    if (req.query_string.len == 0 or std.mem.indexOfAny(u8, req.query_string, "\r\n") != null) {
        return mer.redirect(destination, .permanent_redirect);
    }
    const target = std.fmt.allocPrint(req.allocator, "{s}?{s}", .{ destination, req.query_string }) catch
        return mer.redirect(destination, .permanent_redirect);
    return mer.redirect(target, .permanent_redirect);
}
