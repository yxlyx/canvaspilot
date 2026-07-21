// app/wiki/index.zig — generated wiki index for the M2 prototype.
//
// Lists generated workspace wiki pages. Live sessions use backend metadata;
// fixtures are reachable only through the explicit demo gate.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Wiki",
    .description = "Browse generated WikiBase wiki pages with citations.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const use_mock = lib.m3.isExplicitDemo(req);
    var live_pages: ?[]const lib.types.WikiPageResponse = null;
    var source_count: ?usize = null;
    var deck_count: ?usize = null;

    if (!use_mock) {
        const pages_result = lib.backend.listWikiPages(req.allocator, session.token);
        if (pages_result.value) |parsed_pages| live_pages = parsed_pages.value else return lib.m3.liveError(req, "Wiki", pages_result.status);
        const sources_result = lib.backend.listSources(req.allocator, session.token);
        if (sources_result.value) |sources| source_count = sources.value.len else if (sources_result.status == 401) return lib.m3.liveError(req, "Wiki", 401);
        const decks_result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (decks_result.value) |decks| deck_count = decks.value.len else if (decks_result.status == 401) return lib.m3.liveError(req, "Wiki", 401);
    } else {
        source_count = lib.mock.sources.len;
        deck_count = lib.mock.decks.len;
    }

    var page_count: usize = 0;
    var total_citations: usize = 0;
    if (live_pages) |pages| {
        for (pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index")) continue;
            page_count += 1;
            total_citations += page.citation_count;
        }
    } else {
        page_count = lib.mock.wiki_pages.len;
        for (lib.mock.wiki_pages) |page| total_citations += page.citations.len;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoBanner(req, w) catch return mer.internalError("wiki index render failed");
    const sources_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("wiki index render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, "/chat") catch return mer.internalError("wiki index render failed");

    w.print(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Generated wiki</h1>
        \\    <div class="cp-page-sub">Browse study pages compiled from indexed workspace sources.</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Review sources</a>
        \\    <a class="cp-btn cp-btn-primary" href="{s}">Ask with citations</a>
        \\  </div>
        \\</header>
    , .{ sources_href, chat_href }) catch return mer.internalError("wiki index render failed");

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("wiki index render failed");
    metricCard(w, "Pages", page_count, "generated notes") catch return mer.internalError("wiki index render failed");
    metricCard(w, "Citations", total_citations, "source links") catch return mer.internalError("wiki index render failed");
    optionalMetricCard(w, "Sources", source_count, "workspace records") catch return mer.internalError("wiki index render failed");
    optionalMetricCard(w, "Decks", deck_count, "practice sets") catch return mer.internalError("wiki index render failed");
    w.writeAll("</section>\n") catch return mer.internalError("wiki index render failed");

    w.writeAll(
        \\<section class="cp-card">
        \\  <div class="cp-card-title"><span>Wiki pages</span><span>metadata</span></div>
        \\  <div class="cp-wiki-list">
    ) catch return mer.internalError("wiki index render failed");

    if (page_count == 0) {
        w.writeAll("    <div class=\"cp-empty\">No wiki pages have been generated yet.</div>\n") catch return mer.internalError("wiki index render failed");
    }

    if (live_pages) |pages| {
        for (pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index")) continue;
            renderLivePageRow(req, w, page) catch return mer.internalError("wiki index render failed");
        }
    } else {
        for (lib.mock.wiki_pages) |page| {
            renderMockPageRow(req, w, page) catch return mer.internalError("wiki index render failed");
        }
    }

    w.writeAll(
        \\  </div>
        \\</section>
    ) catch return mer.internalError("wiki index render failed");

    if (live_pages) |pages| {
        w.writeAll("<section class=\"cp-card\" aria-labelledby=\"export-title\"><h2 id=\"export-title\">Export Markdown workspace</h2><p>Select one or more current pages. The backend creates a canonical ZIP archive; no browser-derived Markdown is used.</p><form method=\"post\" action=\"/api/m3\" data-wiki-export><fieldset><legend>Pages to include</legend>") catch return mer.internalError("wiki export render failed");
        for (pages) |page| if (!std.mem.eql(u8, page.page_type, "index")) w.print("<label class=\"cp-check-row\"><input type=\"checkbox\" name=\"page_ids\" value=\"{s}\"> {s}</label>", .{ lib.ui.escapeSafe(req.allocator, page.id), lib.ui.escapeSafe(req.allocator, page.title) }) catch return mer.internalError("wiki export render failed");
        w.writeAll("</fieldset><div class=\"cp-action-row\"><button class=\"cp-btn cp-btn-primary\" name=\"selection\" value=\"selected\" type=\"submit\">Download selected pages</button><button class=\"cp-btn cp-btn-ghost\" name=\"selection\" value=\"all\" type=\"submit\">Download full workspace</button></div><p class=\"cp-form-status\" role=\"status\" aria-live=\"polite\"></p></form></section><script src=\"/m3.js?v=20260721\" defer></script>") catch return mer.internalError("wiki export render failed");
    } else {
        w.writeAll("<section class=\"cp-card\" aria-labelledby=\"export-title\"><h2 id=\"export-title\">Export Markdown workspace</h2><p>This preview would export selected pages or the full workspace as a canonical backend ZIP.</p><div class=\"cp-action-row\"><button class=\"cp-btn cp-btn-primary\" type=\"button\" disabled>Download selected pages</button><button class=\"cp-btn cp-btn-ghost\" type=\"button\" disabled>Download full workspace</button></div><p class=\"cp-muted-copy\">Export is unavailable in synthetic demo mode; no browser-derived file is created.</p></section>") catch return mer.internalError("wiki export render failed");
    }

    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn metricCard(w: *std.Io.Writer, label: []const u8, value: usize, helper: []const u8) !void {
    try w.print(
        \\  <div class="cp-metric-card cp-metric-static">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">{d}</span>
        \\    <span class="cp-metric-sub">{s}</span>
        \\  </div>
    , .{ label, value, helper });
}

fn optionalMetricCard(w: *std.Io.Writer, label: []const u8, value: ?usize, helper: []const u8) !void {
    if (value) |available| return metricCard(w, label, available, helper);
    try w.print(
        \\  <div class="cp-metric-card cp-metric-static">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">Unavailable</span>
        \\    <span class="cp-metric-sub">metric temporarily unavailable</span>
        \\  </div>
    , .{label});
}

fn safeSlug(raw: []const u8) []const u8 {
    if (raw.len == 0 or raw.len > 160) return "";
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return "",
        }
    }
    return raw;
}

fn renderLivePageRow(req: mer.Request, w: *std.Io.Writer, page: lib.types.WikiPageResponse) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
    const href = std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{safeSlug(page.slug)}) catch "/wiki";
    const safe_href = lib.ui.escape(req.allocator, href) catch "/wiki";
    const plural: []const u8 = if (page.citation_count == 1) "citation" else "citations";
    try w.print(
        \\    <a class="cp-wiki-row" href="{s}">
        \\      <span>{s}</span>
        \\      <small>{s}</small>
        \\      <em>{d} {s}</em>
        \\    </a>
    , .{ safe_href, safe_title, safe_summary, page.citation_count, plural });
}

fn renderMockPageRow(req: mer.Request, w: *std.Io.Writer, page: lib.types.WikiPage) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
    const path = std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{page.slug}) catch "/wiki/immutable-lists";
    const href = try lib.m3.demoHref(req.allocator, req, path);
    const count = page.citations.len;
    const plural: []const u8 = if (count == 1) "citation" else "citations";
    try w.print(
        \\    <a class="cp-wiki-row" href="{s}">
        \\      <span>{s}</span>
        \\      <small>{s}</small>
        \\      <em>{d} {s}</em>
        \\    </a>
    , .{ href, safe_title, safe_summary, count, plural });
}
