const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const CSS = @embedFile("_styles.css");

const NavItem = struct {
    href: []const u8,
    label: []const u8,
    match: []const u8,
    icon: []const u8,
};

const NAV_ITEMS = [_]NavItem{
    .{ .href = "/dashboard", .label = "Workspace", .match = "/dashboard", .icon = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M3 10.5 12 3l9 7.5\"/><path d=\"M5 9.5V21h14V9.5\"/><path d=\"M9 21v-7h6v7\"/></svg>" },
    .{ .href = "/sources", .label = "Sources", .match = "/sources", .icon = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"8\" height=\"18\" x=\"3\" y=\"3\" rx=\"1\"/><path d=\"M7 3v18\"/><path d=\"M20.4 18.9c.2.5-.1 1.1-.6 1.3l-1.9.7c-.5.2-1.1-.1-1.3-.6L11.1 5.1c-.2-.5.1-1.1.6-1.3l1.9-.7c.5-.2 1.1.1 1.3.6Z\"/></svg>" },
    .{ .href = "/wiki", .label = "Wiki", .match = "/wiki", .icon = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 7v14\"/><path d=\"M16 12h2M16 8h2\"/><path d=\"M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3Z\"/><path d=\"M21 18a1 1 0 0 0 1-1V4a1 1 0 0 0-1-1h-5a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3Z\"/></svg>" },
    .{ .href = "/chat", .label = "Ask", .match = "/chat", .icon = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M21 15a4 4 0 0 1-4 4H7l-4 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4Z\"/><path d=\"M8 8h8M8 12h5\"/></svg>" },
    .{ .href = "/flashcards", .label = "Flashcards", .match = "/flashcards", .icon = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m12 2 9 5-9 5-9-5 9-5Z\"/><path d=\"m3 12 9 5 9-5\"/><path d=\"m3 17 9 5 9-5\"/></svg>" },
};

fn isWikiReader(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/wiki/")) return false;
    return !std.mem.startsWith(u8, path, "/wiki/knowledge") and
        !std.mem.startsWith(u8, path, "/wiki/activity") and
        !std.mem.startsWith(u8, path, "/wiki/guides");
}

fn documentTitle(body: []const u8) ?[]const u8 {
    const marker = "data-cp-document-title=\"";
    const marker_start = std.mem.indexOf(u8, body, marker) orelse return null;
    const value_start = marker_start + marker.len;
    const value_end = std.mem.indexOfScalar(u8, body[value_start..], '"') orelse return null;
    const title = body[value_start .. value_start + value_end];
    if (title.len == 0 or std.mem.indexOfScalar(u8, title, '<') != null) return null;
    return title;
}

pub fn wrap(allocator: std.mem.Allocator, path: []const u8, body: []const u8, meta: mer.Meta) []const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    const w = &buf.writer;
    const signup_page = std.mem.indexOf(u8, body, "data-auth-mode=\"signup\"") != null;
    const title = if (signup_page) "Create account" else documentTitle(body) orelse if (meta.title.len > 0) meta.title else "WikiBase";
    const desc = if (meta.description.len > 0) meta.description else "A student workspace for sources, wiki notes, cited Q&A, and flashcards.";
    const anonymous_page = std.mem.indexOf(u8, body, "data-cp-auth=\"anonymous\"") != null;
    const explicit_demo = std.mem.indexOf(u8, body, "data-cp-demo=\"true\"") != null;
    const signed_in = std.mem.indexOf(u8, path, "/login") == null and !std.mem.eql(u8, path, "/") and !anonymous_page and !explicit_demo;
    const reader_page = isWikiReader(path);
    const standalone = std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/login") or std.mem.startsWith(u8, path, "/404") or reader_page;

    w.writeAll("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n") catch return body;
    w.print("<title>{s} — WikiBase</title><meta name=\"description\" content=\"{s}\">\n", .{ title, desc }) catch return body;
    w.writeAll(
        \\<link rel="icon" type="image/svg+xml" href="/favicon.svg?v=wikibase-4">
        \\<link rel="apple-touch-icon" href="/apple-touch-icon.png?v=wikibase-3">
        \\<script>document.documentElement.classList.add('js');try{var p=localStorage.getItem('wikibase-theme-preference'),t=localStorage.getItem('wikibase-theme');document.documentElement.dataset.theme=p==='system'?(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'):(p||t||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light'))}catch(e){}</script>
        \\<style>
    ) catch return body;
    w.writeAll(CSS) catch return body;
    w.writeAll("</style>\n") catch return body;
    if (meta.extra_head) |extra| {
        if (std.mem.indexOf(u8, extra, "/app.js") == null) {
            w.writeAll(extra) catch {};
            w.writeAll("\n") catch {};
        }
    }
    w.writeAll("<script defer src=\"/app.js?v=wikibase-9\"></script></head><body><a class=\"cp-skip\" href=\"#main\">Skip to content</a>\n") catch return body;

    if (standalone) {
        if (!std.mem.eql(u8, path, "/") and !reader_page) {
            w.writeAll("<button class=\"cp-standalone-theme\" type=\"button\" data-cp-theme-toggle aria-label=\"Switch to dark mode\"><svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 3a6 6 0 1 0 9 9 9 9 0 1 1-9-9Z\"/></svg></button>") catch return body;
        }
        w.writeAll(body) catch return body;
        w.writeAll("</body></html>") catch return body;
        return buf.written();
    }

    w.writeAll(
        \\<div class="cp-app-shell">
        \\  <aside class="cp-sidebar">
        \\    <a class="cp-brand" href="/"><span class="cp-brand-mark">W</span><span class="cp-brand-name">WikiBase</span></a>
        \\    <button class="cp-course-switcher" type="button" aria-label="Current semester"><span class="cp-course-dot">CS</span><span><strong>Semester 1</strong><small>3 active modules</small></span><svg aria-hidden="true" viewBox="0 0 24 24"><path d="m7 10 5 5 5-5"/></svg></button>
        \\    <nav class="cp-tabs" aria-label="Primary">
    ) catch return body;
    for (NAV_ITEMS) |item| {
        const active = std.mem.startsWith(u8, path, item.match);
        const cls: []const u8 = if (active) "cp-tab cp-tab-active" else "cp-tab";
        const current: []const u8 = if (active) " aria-current=\"page\"" else "";
        const href = lib.m3.demoHrefFor(allocator, explicit_demo, item.href) catch return body;
        w.print("<a class=\"{s}\" href=\"{s}\"{s}>{s}<span>{s}</span></a>\n", .{ cls, href, current, item.icon, item.label }) catch return body;
    }
    w.writeAll("</nav><div class=\"cp-sidebar-foot\">") catch return body;
    if (signed_in) {
        w.writeAll("<a class=\"cp-sidebar-account\" href=\"/settings\"><span class=\"cp-profile-orb\">A</span><span><strong>Account</strong><small>Settings</small></span></a>") catch return body;
    } else if (explicit_demo) {
        w.writeAll("<span class=\"cp-profile-orb\">D</span><span><strong>Demo</strong><small>Illustrative data</small></span>") catch return body;
    } else {
        w.writeAll("<span class=\"cp-profile-orb\">G</span><span><strong>Guest</strong><small>Not signed in</small></span>") catch return body;
    }
    if (signed_in) {
        w.writeAll("<form action=\"/logout\" method=\"post\"><button type=\"submit\" aria-label=\"Sign out\"><svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M10 17l5-5-5-5M15 12H3M15 3h5a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1h-5\"/></svg></button></form>") catch return body;
    } else {
        w.writeAll("<a href=\"/login\" aria-label=\"Sign in\"><svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m9 18 6-6-6-6M15 12H3M15 3h5a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1h-5\"/></svg></a>") catch return body;
    }
    w.writeAll(
        \\    </div>
        \\  </aside>
        \\  <div class="cp-content-shell">
        \\    <div class="cp-shell-tools">
        \\      <button type="button" data-cp-theme-toggle aria-label="Switch to dark mode"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M12 3a6 6 0 1 0 9 9 9 9 0 1 1-9-9Z"/></svg></button>
        \\      <a class="cp-shell-icon" href="/notifications" aria-label="Notifications"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/></svg><i></i></a>
        \\      <a class="cp-profile-orb cp-profile-neutral" href="/settings" aria-label="Account settings"><svg aria-hidden="true" viewBox="0 0 24 24"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg></a>
        \\    </div>
        \\    <header class="cp-mobile-header"><a class="cp-brand" href="/"><span class="cp-brand-mark">W</span><span class="cp-brand-name">WikiBase</span></a>
        \\      <button class="cp-mobile-theme" type="button" data-cp-theme-toggle aria-label="Switch to dark mode"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M12 3a6 6 0 1 0 9 9 9 9 0 1 1-9-9Z"/></svg></button>
        \\      <details class="cp-mobile-menu"><summary aria-label="Open navigation menu"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></svg></summary><nav aria-label="Mobile menu">
    ) catch return body;
    for (NAV_ITEMS) |item| {
        const active = std.mem.startsWith(u8, path, item.match);
        const current: []const u8 = if (active) " aria-current=\"page\"" else "";
        const href = lib.m3.demoHrefFor(allocator, explicit_demo, item.href) catch return body;
        w.print("<a href=\"{s}\"{s}>{s}<span>{s}</span></a>", .{ href, current, item.icon, item.label }) catch return body;
    }
    const notification_href = lib.m3.demoHrefFor(allocator, explicit_demo, "/notifications") catch return body;
    const settings_href = lib.m3.demoHrefFor(allocator, explicit_demo, "/settings") catch return body;
    w.print("<a href=\"{s}\"><svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4\"/></svg><span>Notifications</span></a><a href=\"{s}\"><svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M12 2v3M12 19v3M4.9 4.9 7 7M17 17l2.1 2.1M2 12h3M19 12h3M4.9 19.1 7 17M17 7l2.1-2.1\"/></svg><span>Settings</span></a>", .{ notification_href, settings_href }) catch return body;
    if (signed_in) {
        w.writeAll("<form action=\"/logout\" method=\"post\" class=\"cp-mobile-account\"><input type=\"hidden\" name=\"action\" value=\"logout\"><button type=\"submit\">Sign out</button></form>") catch return body;
    } else {
        w.writeAll("<a class=\"cp-mobile-account\" href=\"/login\">Sign in</a>") catch return body;
    }
    w.writeAll("</nav></details></header><main class=\"cp-main\" id=\"main\" tabindex=\"-1\">") catch return body;
    w.writeAll(body) catch return body;
    w.writeAll("</main></div></div><nav class=\"cp-bottomnav\" aria-label=\"Primary mobile\">") catch return body;
    for (NAV_ITEMS) |item| {
        const active = std.mem.startsWith(u8, path, item.match);
        const cls: []const u8 = if (active) "cp-bottom-item cp-bottom-active" else "cp-bottom-item";
        const current: []const u8 = if (active) " aria-current=\"page\"" else "";
        const href = lib.m3.demoHrefFor(allocator, explicit_demo, item.href) catch return body;
        w.print("<a class=\"{s}\" href=\"{s}\"{s}>{s}<span>{s}</span></a>", .{ cls, href, current, item.icon, item.label }) catch return body;
    }
    w.writeAll("</nav></body></html>") catch return body;
    return buf.written();
}
