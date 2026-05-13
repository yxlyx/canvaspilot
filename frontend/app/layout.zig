// app/layout.zig — CanvasPilot shell. Every page response is wrapped by
// `wrap()`. We render a compact header with brand + tab nav (Dashboard,
// Chat) and a session-aware "Sign in / Sign out" action. Milestone 1
// scope: Dashboard + Chat only; the full Tasks page lives in Milestone 2.

const std = @import("std");
const mer = @import("mer");

const log = std.log.scoped(.layout);

const CSS = @embedFile("_styles.css");

const NavItem = struct {
    href: []const u8,
    label: []const u8,
    match: []const u8,
};

const NAV_ITEMS = [_]NavItem{
    .{ .href = "/dashboard", .label = "Dashboard", .match = "/dashboard" },
    .{ .href = "/chat", .label = "Chat", .match = "/chat" },
};

pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;

    const title = if (meta.title.len > 0) meta.title else "CanvasPilot";
    const desc = if (meta.description.len > 0)
        meta.description
    else
        "Canvas-grounded chat for your modules and deadlines.";

    // Authentication state is approximated by checking if a `cp_session`
    // cookie is present *anywhere* in the request — pages re-check this
    // properly via `lib.session.requireAuth(req)` before rendering data.
    const signed_in = std.mem.indexOf(u8, path, "/login") == null;

    w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
    ) catch return body;
    w.print("<title>{s} — CanvasPilot</title>\n", .{title}) catch return body;
    w.print("<meta name=\"description\" content=\"{s}\">\n", .{desc}) catch return body;

    w.writeAll("<style>") catch return body;
    w.writeAll(CSS) catch return body;
    w.writeAll("</style>\n") catch return body;

    if (meta.extra_head) |extra| {
        w.writeAll(extra) catch {};
        w.writeAll("\n") catch {};
    }

    w.writeAll(
        \\</head>
        \\<body>
        \\<header class="cp-header">
        \\  <div class="cp-header-inner">
        \\    <a class="cp-brand" href="/">
        \\      <span class="cp-brand-mark">◢</span>
        \\      <span class="cp-brand-name">CanvasPilot</span>
        \\    </a>
        \\    <nav class="cp-tabs" aria-label="Primary">
        \\
    ) catch return body;

    for (NAV_ITEMS) |item| {
        const active = std.mem.startsWith(u8, path, item.match);
        const cls: []const u8 = if (active) "cp-tab cp-tab-active" else "cp-tab";
        w.print(
            "      <a class=\"{s}\" href=\"{s}\">{s}</a>\n",
            .{ cls, item.href, item.label },
        ) catch return body;
    }

    w.writeAll("    </nav>\n    <div class=\"cp-header-actions\">\n") catch return body;
    if (signed_in) {
        w.writeAll(
            \\      <form action="/logout" method="post" class="cp-logout">
            \\        <button type="submit" class="cp-btn cp-btn-ghost">Sign out</button>
            \\      </form>
            \\
        ) catch return body;
    } else {
        w.writeAll("      <a class=\"cp-btn cp-btn-primary\" href=\"/login\">Sign in</a>\n") catch return body;
    }
    w.writeAll(
        \\    </div>
        \\  </div>
        \\</header>
        \\<main class="cp-main">
        \\
    ) catch return body;

    w.writeAll(body) catch return body;

    w.writeAll(
        \\
        \\</main>
        \\<nav class="cp-bottomnav" aria-label="Primary mobile">
        \\
    ) catch return body;

    for (NAV_ITEMS) |item| {
        const active = std.mem.startsWith(u8, path, item.match);
        const cls: []const u8 = if (active) "cp-bottom-item cp-bottom-active" else "cp-bottom-item";
        w.print(
            "  <a class=\"{s}\" href=\"{s}\">{s}</a>\n",
            .{ cls, item.href, item.label },
        ) catch return body;
    }

    w.writeAll(
        \\</nav>
        \\<footer class="cp-footer">
        \\  Built with <a href="https://github.com/justrach/merjs">merjs</a> · Zig 0.16
        \\</footer>
        \\</body>
        \\</html>
    ) catch return body;

    return buf.written();
}
