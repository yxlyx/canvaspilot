const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Wiki",
    .description = "Browse connected source-grounded wiki topics.",
};

const ICON_SEARCH = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"11\" cy=\"11\" r=\"8\"/><path d=\"m21 21-4.3-4.3\"/></svg>";
const ICON_BOOK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 7v14\"/><path d=\"M16 12h2M16 8h2\"/><path d=\"M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3Z\"/><path d=\"M21 18a1 1 0 0 0 1-1V4a1 1 0 0 0-1-1h-5a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3Z\"/></svg>";
const ICON_NETWORK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"6\" height=\"6\" x=\"9\" y=\"2\" rx=\"1\"/><rect width=\"6\" height=\"6\" x=\"3\" y=\"16\" rx=\"1\"/><rect width=\"6\" height=\"6\" x=\"15\" y=\"16\" rx=\"1\"/><path d=\"M12 8v4M6 16v-2h12v2\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M5 12h14M13 6l6 6-6 6\"/></svg>";
const ICON_ALERT = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 7v6M12 17h.01\"/></svg>";

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const use_mock = lib.m3.isExplicitDemo(req);
    const raw_query = req.queryParam("q") orelse "";
    const raw_module = req.queryParam("module") orelse "";
    const query = lib.form.decode(req.allocator, raw_query) catch raw_query;
    const requested_module = lib.form.decode(req.allocator, raw_module) catch raw_module;
    const unsupported_module = requested_module.len > 0 and !std.mem.eql(u8, requested_module, "Workspace");
    const filter_module: []const u8 = if (unsupported_module) "Workspace" else requested_module;
    var live_pages: ?[]const lib.types.WikiPageResponse = null;
    var source_count: ?usize = null;
    var deck_count: ?usize = null;

    if (!use_mock) {
        const pages_result = lib.backend.listWikiPages(req.allocator, session.token);
        if (pages_result.value) |pages| live_pages = pages.value else return lib.m3.liveError(req, "Wiki", pages_result.status);
        const sources_result = lib.backend.listSources(req.allocator, session.token);
        if (sources_result.value) |sources_result_value| source_count = sources_result_value.value.len else if (sources_result.status == 401) return lib.m3.liveError(req, "Wiki", 401);
        const decks_result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (decks_result.value) |decks| deck_count = decks.value.len else if (decks_result.status == 401) return lib.m3.liveError(req, "Wiki", 401);
    } else {
        source_count = lib.mock.sources.len;
        deck_count = lib.mock.decks.len;
    }

    var topic_count: usize = 0;
    var total_citations: usize = 0;
    var shown_count: usize = 0;
    if (live_pages) |pages| {
        for (pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index")) continue;
            topic_count += 1;
            total_citations += page.citation_count;
            if (matchesLivePage(page, query, filter_module)) shown_count += 1;
        }
    } else {
        topic_count = lib.mock.wiki_pages.len;
        for (lib.mock.wiki_pages) |page| {
            total_citations += page.citations.len;
            if (matchesMockPage(page, query, filter_module)) shown_count += 1;
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("wiki index render failed");
    w.print("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">{s}{d} connected topics</p><h1 class=\"cp-page-title\">Knowledge wiki</h1></div>", .{ if (use_mock) "Synthetic demo · " else "", topic_count }) catch return mer.internalError("wiki index render failed");
    if (live_pages != null) w.writeAll("<div class=\"cp-page-actions\"><button class=\"button button-secondary button-small\" id=\"cp-open-wiki-export\" type=\"button\">Export Markdown</button></div>") catch return mer.internalError("wiki index render failed");
    w.writeAll("</header>") catch return mer.internalError("wiki index render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.wiki_tabs, "articles", "Wiki", use_mock) catch return mer.internalError("wiki tabs failed");
    w.print("<div class=\"wiki-page page-grid\"><section class=\"wiki-overview surface\"><div><p class=\"eyebrow\">{s}</p><h2>Follow an idea from source to understanding.</h2><p>Every topic shows its evidence, neighbours, and missing links.</p></div><div class=\"wiki-map\" aria-label=\"{s} for {d} connected topics\"><span class=\"map-core\">{d}<small>topics</small></span>", .{ if (use_mock) "Your connected course map" else "Connected knowledge inventory", if (use_mock) "Illustrative coverage map" else "Inventory map", topic_count, topic_count }) catch return mer.internalError("wiki index render failed");
    if (use_mock) {
        const strong: usize = if (topic_count > 0) 1 else 0;
        const growing: usize = topic_count - strong;
        w.print("<i class=\"map-orbit orbit-0\"><b>Strong {d}</b></i><i class=\"map-orbit orbit-1\"><b>Growing {d}</b></i><i class=\"map-orbit orbit-2\"><b>Need sources 0</b></i>", .{ strong, growing }) catch return mer.internalError("wiki index render failed");
    } else {
        w.print("<i class=\"map-orbit orbit-0\"><b>{d} citations</b></i>", .{total_citations}) catch return mer.internalError("wiki index render failed");
        optionalMapCount(w, "orbit-1", source_count, "sources") catch return mer.internalError("wiki index render failed");
        optionalMapCount(w, "orbit-2", deck_count, "decks") catch return mer.internalError("wiki index render failed");
    }
    w.writeAll("</div></section>") catch return mer.internalError("wiki index render failed");
    const safe_query = lib.ui.escapeSafe(req.allocator, query);
    const safe_module = lib.ui.escapeSafe(req.allocator, filter_module);
    w.writeAll("<form class=\"wiki-controls\" method=\"get\" action=\"/wiki\"><label class=\"source-search\">") catch return mer.internalError("wiki index render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("wiki index render failed");
    w.print("<input class=\"search-field\" id=\"cp-wiki-search\" name=\"q\" value=\"{s}\" placeholder=\"Search concepts, citations, or source titles\" aria-label=\"Search wiki\"></label>", .{safe_query}) catch return mer.internalError("wiki index render failed");
    if (use_mock) w.writeAll("<input type=\"hidden\" name=\"mock\" value=\"1\">") catch return mer.internalError("wiki index render failed");
    w.print("<div class=\"filter-row\"><button class=\"filter-button{s}\" type=\"submit\" name=\"module\" value=\"\" data-wiki-module=\"All\" aria-pressed=\"{s}\">All modules</button><button class=\"filter-button{s}\" type=\"submit\" name=\"module\" value=\"Workspace\" data-wiki-module=\"Workspace\" aria-pressed=\"{s}\">Workspace</button><button class=\"wiki-search-submit\" type=\"submit\" name=\"module\" value=\"{s}\">Search wiki</button></div></form>", .{ if (filter_module.len == 0) " active" else "", if (filter_module.len == 0) "true" else "false", if (std.mem.eql(u8, filter_module, "Workspace")) " active" else "", if (std.mem.eql(u8, filter_module, "Workspace")) "true" else "false", safe_module }) catch return mer.internalError("wiki index render failed");
    if (unsupported_module) w.print("<p class=\"cp-inline-status\" role=\"status\">Wiki pages do not expose per-module ownership yet. Showing all workspace articles instead of an empty <strong>{s}</strong> view.</p>", .{lib.ui.escapeSafe(req.allocator, requested_module)}) catch return mer.internalError("wiki index render failed");
    w.writeAll("<section class=\"article-grid\" id=\"cp-wiki-grid\" aria-live=\"polite\">") catch return mer.internalError("wiki index render failed");
    if (live_pages) |pages| {
        for (pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index") or !matchesLivePage(page, query, filter_module)) continue;
            renderLiveArticle(req, w, page) catch return mer.internalError("wiki index render failed");
        }
    } else {
        for (lib.mock.wiki_pages) |page| {
            if (!matchesMockPage(page, query, filter_module)) continue;
            renderMockArticle(req, w, page) catch return mer.internalError("wiki index render failed");
        }
    }
    if (shown_count == 0) {
        const clear_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("wiki index render failed");
        if (topic_count == 0 and query.len == 0 and filter_module.len == 0) {
            w.writeAll("<div class=\"empty-state surface\"><h2>No wiki pages have been generated yet.</h2><p>Import sources, then generate a source-grounded page.</p></div>") catch return mer.internalError("wiki index render failed");
        } else {
            w.print("<div class=\"empty-state surface\"><h2>No connected topics found</h2><p>Try another module or search term.</p><a class=\"button button-secondary\" href=\"{s}\">Clear search</a></div>", .{clear_href}) catch return mer.internalError("wiki index render failed");
        }
    }
    w.writeAll("</section><div class=\"empty-state surface\" id=\"cp-wiki-empty\" hidden><h2>No connected topics found</h2><p>Try another module or search term.</p><button class=\"button button-secondary\" id=\"cp-clear-wiki-search\" type=\"button\">Clear search</button></div>") catch return mer.internalError("wiki index render failed");
    const sources_href = lib.m3.demoHref(req.allocator, req, "/sources") catch return mer.internalError("wiki index render failed");
    w.print("<section class=\"wiki-gap surface\"><span class=\"gap-icon\">{s}</span><div><strong>Strengthen the evidence graph.</strong><p>Add sources for topics with sparse citation coverage.</p></div><a class=\"button button-secondary button-small\" href=\"{s}\">Add supporting sources</a></section></div>", .{ ICON_ALERT, sources_href }) catch return mer.internalError("wiki index render failed");

    if (live_pages) |pages| {
        w.writeAll("<dialog class=\"cp-export-dialog\" id=\"cp-wiki-export-dialog\" aria-labelledby=\"export-title\"><form method=\"dialog\" class=\"cp-dialog-close\"><button type=\"submit\" aria-label=\"Close export dialog\">×</button></form><p class=\"eyebrow\">Portable knowledge</p><h2 id=\"export-title\">Export Markdown workspace</h2><p>Select current pages. The backend creates the canonical ZIP; no browser-derived Markdown is used.</p><form method=\"post\" action=\"/api/m3\" data-wiki-export><fieldset><legend>Pages to include</legend>") catch return mer.internalError("wiki export render failed");
        for (pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index")) continue;
            w.print("<label class=\"cp-check-row\"><input type=\"checkbox\" name=\"page_ids\" value=\"{s}\"> {s}</label>", .{ lib.ui.escapeSafe(req.allocator, page.id), lib.ui.escapeSafe(req.allocator, page.title) }) catch return mer.internalError("wiki export render failed");
        }
        w.writeAll("</fieldset><div class=\"cp-action-row\"><button class=\"cp-btn cp-btn-primary\" name=\"selection\" value=\"selected\" type=\"submit\">Download selected pages</button><button class=\"cp-btn cp-btn-ghost\" name=\"selection\" value=\"all\" type=\"submit\">Download full workspace</button></div><p class=\"cp-form-status\" role=\"status\" aria-live=\"polite\"></p></form></dialog><script src=\"/m3.js?v=20260721\" defer></script>") catch return mer.internalError("wiki export render failed");
    }
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderArticle(w: *std.Io.Writer, slug: []const u8, module: []const u8, sources: []const u8, title: []const u8, summary: []const u8, topics: []const u8, coverage: []const u8, updated: []const u8, icon: []const u8) !void {
    try w.print("<a class=\"article-card surface\" href=\"/wiki/{s}\" data-module=\"{s}\" data-search=\"{s} {s} {s}\"><div class=\"article-card-top\"><span class=\"article-glyph\">{s}</span><span class=\"status-pill status-{s}\">{s}</span></div><div><small>{s} · {s} sources</small><h2>{s}</h2><p>{s}</p></div><div class=\"topic-row\">", .{ slug, module, title, summary, topics, icon, if (coverage[0] == 'S') "good" else "info", coverage, module, sources, title, summary });
    var iterator = std.mem.splitSequence(u8, topics, " · ");
    while (iterator.next()) |topic| try w.print("<span>{s}</span>", .{topic});
    try w.print("</div><footer><span>Updated {s}</span><b>Read article {s}</b></footer></a>", .{ updated, ICON_ARROW });
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn matchesModule(selected: []const u8) bool {
    return selected.len == 0 or std.mem.eql(u8, selected, "Workspace");
}

fn matchesLivePage(page: lib.types.WikiPageResponse, query: []const u8, module: []const u8) bool {
    if (!matchesModule(module)) return false;
    if (containsIgnoreCase(page.title, query) or containsIgnoreCase(page.summary, query) or containsIgnoreCase(page.markdown, query) or containsIgnoreCase(page.page_type, query)) return true;
    for (page.citations) |citation| {
        if (containsIgnoreCase(citation.source_title, query) or containsIgnoreCase(citation.snippet, query) or containsIgnoreCase(citation.citation_ref, query)) return true;
    }
    return false;
}

fn matchesMockPage(page: lib.types.WikiPage, query: []const u8, module: []const u8) bool {
    if (!matchesModule(module)) return false;
    if (containsIgnoreCase(page.title, query) or containsIgnoreCase(page.summary, query) or containsIgnoreCase(page.markdown, query)) return true;
    for (page.topics) |topic| if (containsIgnoreCase(topic, query)) return true;
    for (page.citations) |citation| {
        if (containsIgnoreCase(citation.title, query) or containsIgnoreCase(citation.snippet, query)) return true;
    }
    return false;
}

fn optionalMapCount(w: *std.Io.Writer, orbit: []const u8, value: ?usize, label: []const u8) !void {
    if (value) |available| {
        try w.print("<i class=\"map-orbit {s}\"><b>{d} {s}</b></i>", .{ orbit, available, label });
    } else {
        try w.print("<i class=\"map-orbit {s}\"><b>{s} not reported</b></i>", .{ orbit, label });
    }
}

fn metricCard(w: *std.Io.Writer, label: []const u8, value: usize, helper: []const u8) !void {
    try w.print("<div class=\"cp-metric-card cp-metric-static\"><span class=\"cp-metric-label\">{s}</span><span class=\"cp-metric-value\">{d}</span><span class=\"cp-metric-sub\">{s}</span></div>", .{ label, value, helper });
}

fn optionalMetricCard(w: *std.Io.Writer, label: []const u8, value: ?usize) !void {
    if (value) |available| return metricCard(w, label, available, "workspace records");
    try w.print("<div class=\"cp-metric-card cp-metric-static\"><span class=\"cp-metric-label\">{s}</span><span class=\"cp-metric-value\">Unavailable</span><span class=\"cp-metric-sub\">metric temporarily unavailable</span></div>", .{label});
}

fn safeSlug(raw: []const u8) []const u8 {
    if (raw.len == 0 or raw.len > 160) return "";
    for (raw) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return "",
    };
    return raw;
}

fn renderLiveArticle(req: mer.Request, w: *std.Io.Writer, page: lib.types.WikiPageResponse) !void {
    const slug = safeSlug(page.slug);
    const href = if (slug.len > 0) try std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{slug}) else "/wiki";
    const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
    const safe_type = lib.ui.escapeSafe(req.allocator, page.page_type);
    const coverage: []const u8 = if (page.citation_count > 0) "Cited" else "Needs evidence";
    const when = lib.time.formatRelative(req.allocator, page.updated_at, lib.time.nowSecs()) catch "—";
    try w.print("<a class=\"article-card surface\" href=\"{s}\" data-module=\"Workspace\" data-search=\"{s} {s}\"><div class=\"article-card-top\"><span class=\"article-glyph\">{s}</span><span class=\"status-pill status-{s}\">{s}</span></div><div><small>{s} · {d} sources · {d} citations</small><h2>{s}</h2><p>{s}</p></div><div class=\"topic-row\"><span>{d} backlinks</span><span>Created {s}</span></div><footer><span>Updated {s}</span><b>Read article {s}</b></footer></a>", .{ href, safe_title, safe_summary, ICON_BOOK, if (page.citation_count > 0) "good" else "warn", coverage, safe_type, page.source_ids.len, page.citation_count, safe_title, safe_summary, page.backlinks.len, lib.ui.escapeSafe(req.allocator, page.created_at), when, ICON_ARROW });
}

fn renderMockArticle(req: mer.Request, w: *std.Io.Writer, page: lib.types.WikiPage) !void {
    const slug = safeSlug(page.slug);
    const path = if (slug.len > 0) try std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{slug}) else "/wiki";
    const href = try lib.m3.demoHref(req.allocator, req, path);
    const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
    const coverage: []const u8 = if (page.citations.len > 1) "Strong" else "Growing";
    const when = lib.time.formatRelative(req.allocator, page.updated_at, lib.time.nowSecs()) catch "—";
    try w.print("<a class=\"article-card surface\" href=\"{s}\" data-module=\"Workspace\" data-search=\"{s} {s}\"><div class=\"article-card-top\"><span class=\"article-glyph\">{s}</span><span class=\"status-pill status-{s}\">{s}</span></div><div><small>Synthetic demo · {d} citations</small><h2>{s}</h2><p>{s}</p></div><div class=\"topic-row\">", .{ href, safe_title, safe_summary, ICON_NETWORK, if (page.citations.len > 1) "good" else "info", coverage, page.citations.len, safe_title, safe_summary });
    for (page.topics) |topic| try w.print("<span>{s}</span>", .{lib.ui.escapeSafe(req.allocator, topic)});
    try w.print("</div><footer><span>Updated {s}</span><b>Read article {s}</b></footer></a>", .{ when, ICON_ARROW });
}
