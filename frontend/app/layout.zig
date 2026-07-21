// app/layout.zig — WikiBase shell. Every page response is wrapped by
// `wrap()`. We render the sidebar navigation, mobile bottom nav, and a
// session-aware "Sign in / Sign out" action.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const log = std.log.scoped(.layout);

const CSS = @embedFile("_styles.css");

const NavItem = struct {
    href: []const u8,
    label: []const u8,
    match: []const u8,
};

const NAV_ITEMS = [_]NavItem{
    .{ .href = "/dashboard", .label = "Workspace", .match = "/dashboard" },
    .{ .href = "/sources", .label = "Sources", .match = "/sources" },
    .{ .href = "/wiki", .label = "Wiki", .match = "/wiki" },
    .{ .href = "/flashcards", .label = "Flashcards", .match = "/flashcards" },
    .{ .href = "/chat", .label = "Chat", .match = "/chat" },
    .{ .href = "/outputs", .label = "Outputs", .match = "/outputs" },
    .{ .href = "/progress", .label = "Knowledge", .match = "/progress" },
    .{ .href = "/health", .label = "Health", .match = "/health" },
    .{ .href = "/history", .label = "History", .match = "/history" },
    .{ .href = "/marked-papers", .label = "Papers", .match = "/marked-papers" },
    .{ .href = "/settings/providers", .label = "Providers", .match = "/settings/providers" },
};

pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;

    const title = if (meta.title.len > 0) meta.title else "WikiBase";
    const desc = if (meta.description.len > 0)
        meta.description
    else
        "A student workspace for sources, wiki notes, cited Q&A, and flashcards.";
    const anonymous_page = std.mem.indexOf(u8, body, "data-cp-auth=\"anonymous\"") != null;
    const explicit_demo = std.mem.indexOf(u8, body, "data-cp-demo=\"true\"") != null;
    const signed_in = std.mem.indexOf(u8, path, "/login") == null and !std.mem.eql(u8, path, "/") and !anonymous_page;

    w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\
    ) catch return body;
    w.print("<title>{s} — WikiBase</title>\n", .{title}) catch return body;
    w.print("<meta name=\"description\" content=\"{s}\">\n", .{desc}) catch return body;
    w.writeAll(
        \\<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png?v=wikibase-2">
        \\<link rel="icon" type="image/png" sizes="512x512" href="/icon-512.png?v=wikibase-2">
        \\<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=wikibase-2">
        \\
    ) catch return body;

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
        \\<a class="cp-skip" href="#main">Skip to content</a>
        \\<div class="cp-app-shell">
        \\  <aside class="cp-sidebar">
        \\    <a class="cp-brand" href="/">
        \\      <span class="cp-brand-mark"><img src="/icon-512.png?v=wikibase-2" alt="WikiBase" width="36" height="36"></span>
        \\      <span>
        \\        <span class="cp-brand-name">WikiBase</span>
        \\        <span class="cp-brand-sub">Course workspace</span>
        \\      </span>
        \\    </a>
        \\    <nav class="cp-tabs" aria-label="Primary">
        \\
    ) catch return body;

    for (NAV_ITEMS) |item| {
        const active = std.mem.startsWith(u8, path, item.match);
        const cls: []const u8 = if (active) "cp-tab cp-tab-active" else "cp-tab";
        const current: []const u8 = if (active) " aria-current=\"page\"" else "";
        const href = lib.m3.demoHrefFor(allocator, explicit_demo, item.href) catch return body;
        w.print(
            "      <a class=\"{s}\" href=\"{s}\"{s}>{s}</a>\n",
            .{ cls, href, current, item.label },
        ) catch return body;
    }

    w.writeAll(
        \\    </nav>
        \\    <div class="cp-sidebar-card">
        \\      <div class="cp-sidebar-label">Prototype flow</div>
        \\      <strong>Sources → Wiki → Q&amp;A → Cards</strong>
        \\    </div>
        \\    <div class="cp-header-actions">
        \\
    ) catch return body;
    if (signed_in) {
        w.writeAll(
            \\      <form action="/logout" method="post" class="cp-logout">
            \\        <input type="hidden" name="action" value="logout">
            \\        <button type="submit" class="cp-btn cp-btn-ghost">Sign out</button>
            \\      </form>
            \\
        ) catch return body;
    } else {
        w.writeAll("      <a class=\"cp-btn cp-btn-primary\" href=\"/login\">Sign in</a>\n") catch return body;
    }
    w.writeAll(
        \\    </div>
        \\  </aside>
        \\  <div class="cp-content-shell">
        \\    <header class="cp-mobile-header">
        \\      <a class="cp-brand" href="/">
        \\        <span class="cp-brand-mark"><img src="/icon-512.png?v=wikibase-2" alt="WikiBase" width="36" height="36"></span>
        \\        <span class="cp-brand-name">WikiBase</span>
        \\      </a>
        \\    </header>
        \\    <main class="cp-main" id="main" tabindex="-1">
        \\
    ) catch return body;

    w.writeAll(body) catch return body;

    w.writeAll(
        \\
        \\    </main>
        \\    <footer class="cp-footer">
        \\      Built with <a href="https://github.com/justrach/merjs">merjs</a> · Zig 0.16
        \\    </footer>
        \\  </div>
        \\</div>
        \\<nav class="cp-bottomnav" aria-label="Primary mobile">
        \\
    ) catch return body;

    for (NAV_ITEMS) |item| {
        const active = std.mem.startsWith(u8, path, item.match);
        const cls: []const u8 = if (active) "cp-bottom-item cp-bottom-active" else "cp-bottom-item";
        const current: []const u8 = if (active) " aria-current=\"page\"" else "";
        const href = lib.m3.demoHrefFor(allocator, explicit_demo, item.href) catch return body;
        w.print(
            "  <a class=\"{s}\" href=\"{s}\"{s}>{s}</a>\n",
            .{ cls, href, current, item.label },
        ) catch return body;
    }

    w.writeAll(
        \\</nav>
        \\</body>
        \\</html>
    ) catch return body;

    return buf.written();
}
