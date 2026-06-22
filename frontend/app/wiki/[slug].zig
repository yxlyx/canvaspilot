// app/wiki/[slug].zig — generated wiki page prototype.
//
// Renders cited study notes from workspace source fixtures. The dynamic slug
// route mirrors the eventual generated wiki page URL shape.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Wiki",
    .description = "Generated study wiki page with source citations.",
};

pub fn render(req: mer.Request) mer.Response {
    const slug = req.param("slug") orelse "immutable-lists";
    const page = findPage(slug) orelse return renderMissing(req, slug);
    const now_secs = lib.time.nowSecs();

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    const safe_title = lib.ui.escape(req.allocator, page.title) catch page.title;
    const safe_summary = lib.ui.escape(req.allocator, page.summary) catch page.summary;
    const when = lib.time.formatRelative(req.allocator, page.updated_at, now_secs) catch "—";

    w.print(
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
    , .{ safe_title, safe_summary }) catch return mer.internalError("wiki render failed");

    w.writeAll(
        \\<div class="cp-wiki-layout">
        \\  <article class="cp-card cp-wiki-article">
    ) catch return mer.internalError("wiki render failed");

    renderMarkdown(req, w, page.markdown) catch return mer.internalError("wiki render failed");

    w.print(
        \\    <div class="cp-wiki-updated">Generated from indexed workspace sources · updated {s}</div>
        \\  </article>
        \\  <aside>
        \\    <section class="cp-card">
        \\      <div class="cp-card-title"><span>Topics</span></div>
        \\      <div class="cp-topic-row">
    , .{when}) catch return mer.internalError("wiki render failed");

    for (page.topics) |topic| {
        const safe_topic = lib.ui.escape(req.allocator, topic) catch topic;
        w.print("        <span class=\"cp-topic-pill\">{s}</span>\n", .{safe_topic}) catch return mer.internalError("wiki render failed");
    }

    w.writeAll(
        \\      </div>
        \\    </section>
        \\    <section class="cp-card">
        \\      <div class="cp-card-title"><span>Citations</span></div>
        \\      <div class="cp-citation-list">
    ) catch return mer.internalError("wiki render failed");

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

    w.writeAll(
        \\      </div>
        \\    </section>
        \\    <section class="cp-card">
        \\      <div class="cp-card-title"><span>Ask about this page</span></div>
        \\      <p class="cp-muted-copy">Continue into Q&A with the same source context and cited snippets.</p>
        \\      <a class="cp-btn cp-btn-ghost" href="/chat">Open Q&A</a>
        \\    </section>
        \\  </aside>
        \\</div>
    ) catch return mer.internalError("wiki render failed");

    return lib.ui.htmlResponse(&buf);
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

fn renderMarkdown(req: mer.Request, w: *std.Io.Writer, markdown: []const u8) !void {
    var paragraphs = std.mem.splitSequence(u8, markdown, "\n\n");
    while (paragraphs.next()) |raw_block| {
        const block = std.mem.trim(u8, raw_block, " \n\r\t");
        if (block.len == 0) continue;

        if (std.mem.startsWith(u8, block, "# ")) {
            const text = std.mem.trim(u8, block[2..], " ");
            const safe = lib.ui.escape(req.allocator, text) catch text;
            try w.print("    <h1>{s}</h1>\n", .{safe});
        } else if (std.mem.startsWith(u8, block, "## ")) {
            const text = std.mem.trim(u8, block[3..], " ");
            const safe = lib.ui.escape(req.allocator, text) catch text;
            try w.print("    <h2>{s}</h2>\n", .{safe});
        } else {
            const safe = lib.ui.escape(req.allocator, block) catch block;
            try w.print("    <p>{s}</p>\n", .{safe});
        }
    }
}
