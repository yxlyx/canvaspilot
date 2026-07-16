// app/wiki/index.zig — generated wiki index for the M2 prototype.
//
// Lists generated workspace wiki pages. Authenticated sessions request backend
// wiki metadata and fall back to fixture pages when unavailable.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Wiki",
    .description = "Browse generated WikiBase wiki pages with citations.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = lib.m3.isExplicitDemo(req) or !session.isAuthenticated();
    var live_pages: ?[]const lib.types.WikiPageResponse = null;
    var backend_message: ?[]const u8 = if (use_mock) "Showing prototype wiki fixtures." else null;

    if (!use_mock) {
        const result = lib.backend.listWikiPages(req.allocator, session.token);
        if (result.value) |parsed_pages| {
            if (parsed_pages.value.len > 0) {
                live_pages = parsed_pages.value;
                backend_message = null;
            } else {
                backend_message = "No generated backend wiki pages yet — showing prototype fixtures.";
            }
        } else {
            backend_message = "Backend wiki metadata is unavailable — showing prototype fixtures.";
        }
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
    lib.m3.demoMarker(req, w) catch return mer.internalError("wiki index render failed");
    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("wiki index render failed");
    }
    const sources_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("wiki index render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, "/chat") catch return mer.internalError("wiki index render failed");
    const outputs_href = lib.m3.demoHref(req.allocator, req, "/outputs") catch return mer.internalError("wiki index render failed");
    const history_href = lib.m3.demoHref(req.allocator, req, "/history") catch return mer.internalError("wiki index render failed");

    w.print(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Generated wiki</h1>
        \\    <div class="cp-page-sub">Browse study pages compiled from indexed workspace sources.</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Sources</a>
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Ask with citations</a>
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Outputs</a>
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">History</a>
        \\  </div>
        \\</header>
    , .{ sources_href, chat_href, outputs_href, history_href }) catch return mer.internalError("wiki index render failed");

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("wiki index render failed");
    if (live_pages != null) {
        metricCard(w, "Pages", page_count, "live generated notes") catch return mer.internalError("wiki index render failed");
        metricCard(w, "Citations", total_citations, "live source links") catch return mer.internalError("wiki index render failed");
        metricUnavailable(w, "Sources", "not included in wiki response") catch return mer.internalError("wiki index render failed");
        metricUnavailable(w, "Decks", "not included in wiki response") catch return mer.internalError("wiki index render failed");
    } else {
        metricCard(w, "Pages", page_count, "synthetic generated notes") catch return mer.internalError("wiki index render failed");
        metricCard(w, "Citations", total_citations, "synthetic source links") catch return mer.internalError("wiki index render failed");
        metricCard(w, "Sources", lib.mock.sources.len, "synthetic workspace records") catch return mer.internalError("wiki index render failed");
        metricCard(w, "Decks", lib.mock.decks.len, "synthetic practice sets") catch return mer.internalError("wiki index render failed");
    }
    w.writeAll("</section>\n") catch return mer.internalError("wiki index render failed");

    if (backend_message) |message| {
        const safe_message = lib.ui.escapeSafe(req.allocator, message);
        w.print("<div class=\"cp-status-banner cp-status-info\">{s}</div>\n", .{safe_message}) catch return mer.internalError("wiki index render failed");
    }

    w.writeAll(
        \\<section class="cp-card cp-export-panel" aria-labelledby="wiki-export-title">
        \\  <div class="cp-card-title"><h2 id="wiki-export-title">Markdown export</h2><span>backend unavailable</span></div>
        \\  <fieldset class="cp-export-options" aria-describedby="wiki-export-note"><legend>Select wiki pages</legend>
    ) catch return mer.internalError("wiki index render failed");
    if (live_pages) |pages| {
        for (pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index")) continue;
            const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
            const safe_slug = safeSlug(page.slug);
            w.print("    <label><input type=\"checkbox\" name=\"page\" value=\"{s}\"> {s}</label>\n", .{ safe_slug, safe_title }) catch return mer.internalError("wiki index render failed");
        }
    } else {
        for (lib.mock.wiki_pages) |page| {
            const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
            const safe_slug = safeSlug(page.slug);
            w.print("    <label><input type=\"checkbox\" name=\"page\" value=\"{s}\"> {s}</label>\n", .{ safe_slug, safe_title }) catch return mer.internalError("wiki index render failed");
        }
    }
    w.writeAll(
        \\  </fieldset>
        \\  <div class="cp-action-row">
        \\    <button class="cp-btn cp-btn-ghost" type="button" aria-disabled="true" aria-describedby="wiki-export-note">Export selected</button>
        \\    <button class="cp-btn cp-btn-ghost" type="button" aria-disabled="true" aria-describedby="wiki-export-note">Export full wiki</button>
        \\  </div>
        \\  <p class="cp-muted-copy" id="wiki-export-note">Canonical Markdown and archive generation remain disabled until the authenticated backend export endpoint is available. No placeholder download is created.</p>
        \\</section>
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

    return lib.ui.htmlResponse(&buf);
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

fn metricUnavailable(w: *std.Io.Writer, label: []const u8, helper: []const u8) !void {
    try w.print(
        \\  <div class="cp-metric-card cp-metric-static">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">Unavailable</span>
        \\    <span class="cp-metric-sub">Live count · {s}</span>
        \\  </div>
    , .{ label, helper });
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
    const contextual_href = try lib.m3.demoHref(req.allocator, req, href);
    const safe_href = lib.ui.escapeSafe(req.allocator, contextual_href);
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
    const href = std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{safeSlug(page.slug)}) catch "/wiki/immutable-lists";
    const contextual_href = try lib.m3.demoHref(req.allocator, req, href);
    const safe_href = lib.ui.escapeSafe(req.allocator, contextual_href);
    const count = page.citations.len;
    const plural: []const u8 = if (count == 1) "citation" else "citations";
    try w.print(
        \\    <a class="cp-wiki-row" href="{s}">
        \\      <span>{s}</span>
        \\      <small>{s}</small>
        \\      <em>{d} {s}</em>
        \\    </a>
    , .{ safe_href, safe_title, safe_summary, count, plural });
}
