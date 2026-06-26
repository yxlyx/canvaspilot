// app/wiki/[slug].zig — generated wiki page prototype.
//
// Renders cited study notes from backend wiki pages when available, with
// fixture fallback for offline milestone demos.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Wiki",
    .description = "Generated study wiki page with source citations.",
};

pub fn render(req: mer.Request) mer.Response {
    const slug = req.param("slug") orelse "immutable-lists";
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    const now_secs = lib.time.nowSecs();

    if (!use_mock) {
        const result = lib.backend.getWikiPage(req.allocator, session.token, slug);
        if (result.value) |page| {
            return renderLivePage(req, page.value, now_secs, null);
        }
    }

    const page = findPage(slug) orelse return renderMissing(req, slug);
    const message: ?[]const u8 = if (use_mock) null else "Backend wiki page unavailable — showing prototype fixture content.";
    return renderMockPage(req, page, now_secs, message);
}

fn renderLivePage(
    req: mer.Request,
    page: lib.types.WikiPageResponse,
    now_secs: i64,
    message: ?[]const u8,
) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const safe_title = lib.ui.escape(req.allocator, page.title) catch page.title;
    const safe_summary = lib.ui.escape(req.allocator, page.summary) catch page.summary;
    const when = lib.time.formatRelative(req.allocator, page.updated_at, now_secs) catch "—";

    renderHeader(w, safe_title, safe_summary) catch return mer.internalError("wiki render failed");
    if (message) |copy| {
        const safe_message = lib.ui.escape(req.allocator, copy) catch copy;
        w.print("<div class=\"cp-status-banner cp-status-info\">{s}</div>\n", .{safe_message}) catch return mer.internalError("wiki render failed");
    }
    renderArticleStart(w) catch return mer.internalError("wiki render failed");
    lib.markdown.renderMarkdown(req.allocator, w, page.markdown) catch return mer.internalError("wiki render failed");
    renderAsideStart(w, when) catch return mer.internalError("wiki render failed");

    w.print("        <span class=\"cp-topic-pill\">{d} source records</span>\n", .{page.source_ids.len}) catch return mer.internalError("wiki render failed");
    for (page.backlinks) |backlink| {
        const safe_backlink = lib.ui.escape(req.allocator, backlink) catch backlink;
        w.print("        <span class=\"cp-topic-pill\">backlink: {s}</span>\n", .{safe_backlink}) catch return mer.internalError("wiki render failed");
    }

    renderCitationsStart(w) catch return mer.internalError("wiki render failed");
    for (page.citations) |citation| {
        const safe_citation_title = lib.ui.escape(req.allocator, citation.source_title) catch citation.source_title;
        const safe_snippet = lib.ui.escape(req.allocator, citation.snippet) catch citation.snippet;
        const safe_ref = lib.ui.escape(req.allocator, citation.citation_ref) catch citation.citation_ref;
        w.print(
            \\        <a class="cp-citation-card" href="/sources">
            \\          <span>{s}</span>
            \\          <small>{s}</small>
            \\          <small>{s}</small>
            \\        </a>
        , .{ safe_citation_title, safe_ref, safe_snippet }) catch return mer.internalError("wiki render failed");
    }
    renderPageEnd(w) catch return mer.internalError("wiki render failed");
    return lib.ui.htmlResponse(&buf);
}

fn renderMockPage(
    req: mer.Request,
    page: lib.types.WikiPage,
    now_secs: i64,
    message: ?[]const u8,
) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const safe_title = lib.ui.escape(req.allocator, page.title) catch page.title;
    const safe_summary = lib.ui.escape(req.allocator, page.summary) catch page.summary;
    const when = lib.time.formatRelative(req.allocator, page.updated_at, now_secs) catch "—";

    renderHeader(w, safe_title, safe_summary) catch return mer.internalError("wiki render failed");
    if (message) |copy| {
        const safe_message = lib.ui.escape(req.allocator, copy) catch copy;
        w.print("<div class=\"cp-status-banner cp-status-info\">{s}</div>\n", .{safe_message}) catch return mer.internalError("wiki render failed");
    }
    renderArticleStart(w) catch return mer.internalError("wiki render failed");
    lib.markdown.renderMarkdown(req.allocator, w, page.markdown) catch return mer.internalError("wiki render failed");
    renderAsideStart(w, when) catch return mer.internalError("wiki render failed");

    for (page.topics) |topic| {
        const safe_topic = lib.ui.escape(req.allocator, topic) catch topic;
        w.print("        <span class=\"cp-topic-pill\">{s}</span>\n", .{safe_topic}) catch return mer.internalError("wiki render failed");
    }

    renderCitationsStart(w) catch return mer.internalError("wiki render failed");
    for (page.citations) |citation| {
        const safe_citation_title = lib.ui.escape(req.allocator, citation.title) catch citation.title;
        const safe_snippet = lib.ui.escape(req.allocator, citation.snippet) catch citation.snippet;
        w.print(
            \\        <a class="cp-citation-card" href="{s}">
            \\          <span>{s}</span>
            \\          <small>{s}</small>
            \\        </a>
        , .{ citation.url, safe_citation_title, safe_snippet }) catch return mer.internalError("wiki render failed");
    }
    renderPageEnd(w) catch return mer.internalError("wiki render failed");
    return lib.ui.htmlResponse(&buf);
}

fn renderHeader(w: *std.Io.Writer, title: []const u8, summary: []const u8) !void {
    try w.print(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <div class="cp-page-title">{s}</div>
        \\    <div class="cp-page-sub">{s}</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="/sources">Sources</a>
        \\    <a class="cp-btn cp-btn-primary" href="/flashcards">Practice cards</a>
        \\  </div>
        \\</header>
    , .{ title, summary });
}

fn renderArticleStart(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<div class="cp-wiki-layout">
        \\  <article class="cp-card cp-wiki-article">
    );
}

fn renderAsideStart(w: *std.Io.Writer, when: []const u8) !void {
    try w.print(
        \\    <div class="cp-wiki-updated">Generated from indexed workspace sources · updated {s}</div>
        \\  </article>
        \\  <aside>
        \\    <section class="cp-card">
        \\      <div class="cp-card-title"><span>Topics</span></div>
        \\      <div class="cp-topic-row">
    , .{when});
}

fn renderCitationsStart(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\      </div>
        \\    </section>
        \\    <section class="cp-card">
        \\      <div class="cp-card-title"><span>Citations</span></div>
        \\      <div class="cp-citation-list">
    );
}

fn renderPageEnd(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\      </div>
        \\    </section>
        \\    <section class="cp-card">
        \\      <div class="cp-card-title"><span>Ask about this page</span></div>
        \\      <p class="cp-muted-copy">Continue into Q&A with the same source context and cited snippets.</p>
        \\      <a class="cp-btn cp-btn-ghost" href="/chat">Open Q&A</a>
        \\    </section>
        \\  </aside>
        \\</div>
    );
}

fn findPage(slug: []const u8) ?lib.types.WikiPage {
    for (lib.mock.wiki_pages) |page| {
        if (std.mem.eql(u8, page.slug, slug)) return page;
    }
    return null;
}

fn renderMissing(req: mer.Request, slug: []const u8) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const safe_slug = lib.ui.escape(req.allocator, slug) catch slug;

    w.print(
        \\<section class="cp-landing">
        \\  <h1 class="cp-landing-title">Wiki page not generated yet</h1>
        \\  <p class="cp-landing-sub">No prototype wiki page exists for <strong>{s}</strong>. Choose an available generated page from the workspace.</p>
        \\  <div class="cp-landing-actions">
        \\    <a class="cp-btn cp-btn-primary" href="/wiki/immutable-lists">Open demo wiki</a>
        \\    <a class="cp-btn cp-btn-ghost" href="/dashboard">Workspace</a>
        \\  </div>
        \\</section>
    , .{safe_slug}) catch return mer.internalError("wiki render failed");

    return .{ .status = .not_found, .content_type = .html, .body = buf.written() };
}
