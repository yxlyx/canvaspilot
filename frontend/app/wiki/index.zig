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
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    var live_pages: ?[]const lib.types.WikiPageResponse = null;
    if (!use_mock) {
        const result = lib.backend.listWikiPages(req.allocator, session.token);
        if (result.value) |parsed| {
            if (parsed.value.len > 0) live_pages = parsed.value;
        }
    }
    var topic_count: usize = 28;
    if (live_pages) |pages| {
        topic_count = 0;
        for (pages) |page| if (!std.mem.eql(u8, page.page_type, "index")) {
            topic_count += 1;
        };
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.print(
        \\<header class="cp-page-header"><div><p class="cp-page-kicker">{d} connected topics</p><h1 class="cp-page-title">Knowledge wiki</h1></div></header>
        \\<div class="wiki-page page-grid"><section class="wiki-overview surface"><div><p class="eyebrow">Your connected course map</p><h2>Follow an idea from source to understanding.</h2><p>Every topic shows its evidence, neighbours, and missing links.</p></div><div class="wiki-map" aria-label="{d} connected topics"><span class="map-core">{d}<small>topics</small></span><i class="map-orbit orbit-0"><b>Strong 21</b></i><i class="map-orbit orbit-1"><b>Growing 5</b></i><i class="map-orbit orbit-2"><b>Need sources 2</b></i></div></section>
        \\<section class="wiki-controls"><label class="source-search">
    , .{ topic_count, topic_count, topic_count }) catch return mer.internalError("wiki index render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("wiki index render failed");
    w.writeAll("<input class=\"search-field\" id=\"cp-wiki-search\" placeholder=\"Search concepts, citations, or source titles\" aria-label=\"Search wiki\"></label><div class=\"filter-row\">") catch return mer.internalError("wiki index render failed");
    const labels = [_][]const u8{ "All", "CS2040S", "CS2103T", "IS1108" };
    for (labels, 0..) |label, index| w.print("<button class=\"filter-button{s}\" type=\"button\" data-wiki-module=\"{s}\">{s}</button>", .{ if (index == 0) " active" else "", label, if (index == 0) "All modules" else label }) catch return mer.internalError("wiki index render failed");
    w.writeAll("</div></section><section class=\"article-grid\" id=\"cp-wiki-grid\" aria-live=\"polite\">") catch return mer.internalError("wiki index render failed");
    if (live_pages) |pages| {
        for (pages) |page| {
            if (std.mem.eql(u8, page.page_type, "index")) continue;
            renderLiveArticle(req, w, page) catch return mer.internalError("wiki index render failed");
        }
    } else {
        renderArticle(w, "balanced-search-trees", "CS2040S", "3", "Balanced search trees", "How rotations keep ordered operations logarithmic, with AVL and red-black trees compared.", "AVL trees · Rotations · Invariants", "Strong", "18 min ago", ICON_BOOK) catch return mer.internalError("wiki index render failed");
        renderArticle(w, "graph-traversal", "CS2040S", "4", "Graph traversal", "Breadth-first and depth-first search as systematic strategies for exploring graphs.", "BFS · DFS · Reachability", "Strong", "Yesterday", ICON_NETWORK) catch return mer.internalError("wiki index render failed");
        renderArticle(w, "software-project-quality", "CS2103T", "2", "Software project quality", "A practical map of architecture decisions, testing evidence, and maintainable teamwork.", "Architecture · Testing · Review", "Growing", "2 days ago", ICON_BOOK) catch return mer.internalError("wiki index render failed");
        renderArticle(w, "digital-consent", "IS1108", "2", "Digital consent", "Meaningful consent under information asymmetry, defaults, and platform power.", "Consent · Agency · Platforms", "Growing", "3 days ago", ICON_NETWORK) catch return mer.internalError("wiki index render failed");
    }
    w.writeAll("</section><div class=\"empty-state surface\" id=\"cp-wiki-empty\" hidden><h2>No connected topics found</h2><p>Try another module or search term.</p><button class=\"button button-secondary\" id=\"cp-clear-wiki-search\" type=\"button\">Clear search</button></div><section class=\"wiki-gap surface\"><span class=\"gap-icon\">") catch return mer.internalError("wiki index render failed");
    w.writeAll(ICON_ALERT) catch return mer.internalError("wiki index render failed");
    w.writeAll("</span><div><strong>Two ideas need stronger evidence.</strong><p>Amortised analysis and platform accountability each rely on a single source.</p></div><a class=\"button button-secondary button-small\" href=\"/sources\">Add supporting sources</a></section></div>") catch return mer.internalError("wiki index render failed");
    return lib.ui.htmlResponse(&buf);
}

fn renderArticle(w: *std.Io.Writer, slug: []const u8, module: []const u8, sources: []const u8, title: []const u8, summary: []const u8, topics: []const u8, coverage: []const u8, updated: []const u8, icon: []const u8) !void {
    try w.print("<a class=\"article-card surface\" href=\"/wiki/{s}\" data-module=\"{s}\" data-search=\"{s} {s} {s}\"><div class=\"article-card-top\"><span class=\"article-glyph\">{s}</span><span class=\"status-pill status-{s}\">{s}</span></div><div><small>{s} · {s} sources</small><h2>{s}</h2><p>{s}</p></div><div class=\"topic-row\">", .{ slug, module, title, summary, topics, icon, if (coverage[0] == 'S') "good" else "info", coverage, module, sources, title, summary });
    var iterator = std.mem.splitSequence(u8, topics, " · ");
    while (iterator.next()) |topic| try w.print("<span>{s}</span>", .{topic});
    try w.print("</div><footer><span>Updated {s}</span><b>Read article {s}</b></footer></a>", .{ updated, ICON_ARROW });
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
    const safe_slug = safeSlug(page.slug);
    const safe_title = lib.ui.escape(req.allocator, page.title) catch page.title;
    const safe_summary = lib.ui.escape(req.allocator, page.summary) catch page.summary;
    const coverage: []const u8 = if (page.citation_count > 1) "Strong" else "Growing";
    try w.print("<a class=\"article-card surface\" href=\"/wiki/{s}\" data-module=\"Workspace\" data-search=\"{s} {s}\"><div class=\"article-card-top\"><span class=\"article-glyph\">{s}</span><span class=\"status-pill status-{s}\">{s}</span></div><div><small>Workspace · {d} citations</small><h2>{s}</h2><p>{s}</p></div><div class=\"topic-row\"><span>Source grounded</span><span>{d} references</span></div><footer><span>Recently updated</span><b>Read article {s}</b></footer></a>", .{ safe_slug, safe_title, safe_summary, ICON_BOOK, if (page.citation_count > 1) "good" else "info", coverage, page.citation_count, safe_title, safe_summary, page.citation_count, ICON_ARROW });
}
