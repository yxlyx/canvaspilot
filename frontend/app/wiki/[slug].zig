const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Balanced search trees",
    .description = "A source-grounded knowledge wiki article.",
};

const ICON_BACK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m15 18-6-6 6-6M9 12h12\"/></svg>";
const ICON_SAVE = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M19 21 12 16l-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2Z\"/></svg>";
const ICON_LINK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M10 13a5 5 0 0 0 7.5.5l2-2a5 5 0 0 0-7-7l-1.1 1.1\"/><path d=\"M14 11a5 5 0 0 0-7.5-.5l-2 2a5 5 0 0 0 7 7l1.1-1.1\"/></svg>";
const ICON_MOON = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 3a6 6 0 1 0 9 9 9 9 0 1 1-9-9Z\"/></svg>";

pub fn render(req: mer.Request) mer.Response {
    const slug = req.param("slug") orelse "balanced-search-trees";
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    if (!use_mock) {
        const result = lib.backend.getWikiPage(req.allocator, session.token, slug);
        if (result.value) |parsed| return renderLiveReader(req, parsed.value);
    }
    if (!isFixtureSlug(slug)) return renderMissing(req, slug);
    const title = titleForSlug(slug);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const safe_title = lib.ui.escape(req.allocator, title) catch title;

    w.writeAll("<main id=\"main\" class=\"reader-page\"><header class=\"reader-header\"><a class=\"reader-brand\" href=\"/wiki\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_BACK) catch return mer.internalError("wiki render failed");
    w.writeAll("<span class=\"cp-brand-mark\">W</span><span>Knowledge wiki</span></a><div class=\"reader-tools\"><button id=\"cp-save-article\" type=\"button\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_SAVE) catch return mer.internalError("wiki render failed");
    w.writeAll("<span>Save article</span></button><button id=\"cp-copy-article\" type=\"button\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_LINK) catch return mer.internalError("wiki render failed");
    w.writeAll("<span>Copy link</span></button><button type=\"button\" data-cp-theme-toggle aria-label=\"Switch to dark mode\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_MOON) catch return mer.internalError("wiki render failed");
    w.writeAll("</button></div><a class=\"button button-dark button-small\" href=\"/chat\">Ask about this topic</a></header><div class=\"reader-layout\"><aside class=\"reader-toc\"><p class=\"eyebrow\">On this page</p><nav aria-label=\"Article contents\"><a class=\"active\" href=\"#overview\">Overview</a><a href=\"#invariant\">The invariant</a><a href=\"#rotations\">Rotations</a><a href=\"#comparison\">AVL vs red-black</a><a href=\"#references\">References</a></nav><div><small>Knowledge coverage</small><strong>3 of 4 sources</strong><div class=\"slim-progress\"><i style=\"width:78%\"></i></div></div></aside><article class=\"wiki-article\"><header><div class=\"article-breadcrumb\"><a href=\"/wiki\">Wiki</a><span>/</span><a href=\"/wiki?module=CS2040S\">CS2040S</a></div><h1>") catch return mer.internalError("wiki render failed");
    w.writeAll(safe_title) catch return mer.internalError("wiki render failed");
    w.writeAll(
        \\</h1><p class="article-deck">A balanced search tree preserves the ordering of a binary search tree while controlling height so search, insertion, and deletion remain efficient.</p><div class="article-meta"><span>Updated 18 minutes ago</span><span>·</span><span>7 minute read</span><span>·</span><span>3 connected sources</span></div><div class="topic-row"><span>AVL trees</span><span>Rotations</span><span>Tree height</span></div></header>
        \\<section id="overview"><h2>Overview</h2><p>An ordinary binary search tree can become a chain when keys arrive in an unfortunate order. Its operations then fall from logarithmic to linear time. Balanced variants prevent that collapse by maintaining an additional structural invariant after every update. <sup><a href="#ref-1">1</a></sup></p><blockquote><p>Balance is not perfect symmetry. It is a rule strong enough to keep the tree shallow and cheap enough to repair locally.</p></blockquote></section>
        \\<section id="invariant"><h2>The AVL invariant</h2><p>For each node <code>v</code>, define its balance factor as the height of the left subtree minus the height of the right subtree. An AVL tree requires this value to remain in <code>{-1, 0, 1}</code>.</p><div class="concept-card"><div class="tree-sketch" aria-label="A balanced binary tree diagram"><span class="tree-node root">8</span><span class="tree-line left"></span><span class="tree-line right"></span><span class="tree-node child child-left">4</span><span class="tree-node child child-right">12</span><span class="tree-node leaf leaf-a">2</span><span class="tree-node leaf leaf-b">6</span></div><div><p class="eyebrow">Structural evidence</p><h3>Local balance controls global height.</h3><p>The smallest AVL tree of height <em>h</em> contains the smallest trees of heights <em>h−1</em> and <em>h−2</em>. This Fibonacci-like growth makes the number of nodes exponential in height.</p><a class="citation" href="#ref-2"><span>2</span>Lecture 08, p. 12</a></div></div></section>
        \\<section id="rotations"><h2>Rotations repair the path</h2><p>Insertion changes heights only along the path back to the root. At the first unbalanced node, one single or double rotation restores balance while preserving the in-order sequence.</p><h3>Single rotation</h3><ul><li>Use a right rotation for a left-left imbalance.</li><li>Use a left rotation for a right-right imbalance.</li></ul><h3>Double rotation</h3><p>When the heavy child leans in the opposite direction, rotate the child first and then the unbalanced node. The two local changes bring the middle key to the top. <sup><a href="#ref-1">1</a></sup></p><pre><code>rebalance(node):&#10;  if balance(node) &gt; 1:&#10;    rotate right or left-right&#10;  if balance(node) &lt; -1:&#10;    rotate left or right-left</code></pre></section>
        \\<section id="comparison"><h2>AVL and red-black trees</h2><div class="comparison-table" role="table" aria-label="AVL and red-black tree comparison"><div role="row"><strong role="columnheader">Property</strong><strong role="columnheader">AVL</strong><strong role="columnheader">Red-black</strong></div><div role="row"><span>Balance rule</span><span>Height difference ≤ 1</span><span>Colour and black-height rules</span></div><div role="row"><span>Lookup</span><span>Tighter height bound</span><span>Slightly looser bound</span></div><div role="row"><span>Updates</span><span>May rebalance more often</span><span>Usually fewer rotations</span></div></div><p>Choose the invariant that suits the workload. AVL trees favour lookup-heavy use; red-black trees trade a little height for cheaper frequent updates. <sup><a href="#ref-3">3</a></sup></p></section>
        \\<section id="references" class="references"><p class="eyebrow">Evidence trail</p><h2>References</h2><ol><li id="ref-1"><span>1</span><div><strong>Lecture 08 — Balanced Search Trees</strong><p>CS2040S · pages 8–21</p><a href="/sources">Open source →</a></div></li><li id="ref-2"><span>2</span><div><strong>Tutorial 05 — Tree Height Proof</strong><p>CS2040S · question 3</p><a href="/sources">Open source →</a></div></li><li id="ref-3"><span>3</span><div><strong>Recommended reading — Search Trees</strong><p>Section 13.3</p><a href="/sources">Open source →</a></div></li></ol></section></article>
        \\<aside class="reader-related"><p class="eyebrow">Connected ideas</p><a href="/wiki/graph-traversal"><strong>Tree traversal</strong><span>Neighbour topic</span></a><a href="/wiki/binary-search-trees"><strong>Binary search trees</strong><span>Foundation</span></a><a href="/wiki/amortised-analysis"><strong>Amortised analysis</strong><span>Needs evidence</span></a><div class="backlinks"><small>Linked from</small><strong>4 wiki articles</strong><span>2 grounded answers</span></div></aside></div></main>
    ) catch return mer.internalError("wiki render failed");
    return lib.ui.htmlResponse(&buf);
}

fn renderLiveReader(req: mer.Request, page: lib.types.WikiPageResponse) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const safe_title = lib.ui.escape(req.allocator, page.title) catch page.title;
    const safe_summary = lib.ui.escape(req.allocator, page.summary) catch page.summary;

    w.writeAll("<main id=\"main\" class=\"reader-page\"><header class=\"reader-header\"><a class=\"reader-brand\" href=\"/wiki\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_BACK) catch return mer.internalError("wiki render failed");
    w.writeAll("<span class=\"cp-brand-mark\">W</span><span>Knowledge wiki</span></a><div class=\"reader-tools\"><button id=\"cp-save-article\" type=\"button\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_SAVE) catch return mer.internalError("wiki render failed");
    w.writeAll("<span>Save article</span></button><button id=\"cp-copy-article\" type=\"button\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_LINK) catch return mer.internalError("wiki render failed");
    w.writeAll("<span>Copy link</span></button><button type=\"button\" data-cp-theme-toggle aria-label=\"Switch to dark mode\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_MOON) catch return mer.internalError("wiki render failed");
    w.writeAll("</button></div><a class=\"button button-dark button-small\" href=\"/chat\">Ask about this topic</a></header><div class=\"reader-layout\"><aside class=\"reader-toc\"><p class=\"eyebrow\">On this page</p><nav aria-label=\"Article contents\"><a class=\"active\" href=\"#overview\">Overview</a><a href=\"#references\">References</a></nav><div><small>Knowledge coverage</small>") catch return mer.internalError("wiki render failed");
    w.print("<strong>{d} connected sources</strong><div class=\"slim-progress\"><i style=\"width:78%\"></i></div></div></aside><article class=\"wiki-article\"><header><div class=\"article-breadcrumb\"><a href=\"/wiki\">Wiki</a><span>/</span><span>Workspace</span></div><h1>{s}</h1><p class=\"article-deck\">{s}</p><div class=\"article-meta\"><span>Source-grounded article</span><span>·</span><span>{d} citations</span><span>·</span><span>{d} connected sources</span></div><div class=\"topic-row\"><span>Generated wiki</span><span>Traceable evidence</span></div></header><section id=\"overview\">", .{ page.source_ids.len, safe_title, safe_summary, page.citation_count, page.source_ids.len }) catch return mer.internalError("wiki render failed");
    lib.markdown.renderMarkdown(req.allocator, w, page.markdown) catch return mer.internalError("wiki render failed");
    w.writeAll("</section><section id=\"references\" class=\"references\"><p class=\"eyebrow\">Evidence trail</p><h2>References</h2><ol>") catch return mer.internalError("wiki render failed");
    for (page.citations, 0..) |citation, index| {
        const safe_source = lib.ui.escape(req.allocator, citation.source_title) catch citation.source_title;
        const safe_ref = lib.ui.escape(req.allocator, citation.citation_ref) catch citation.citation_ref;
        w.print("<li><span>{d}</span><div><strong>{s}</strong><p>{s}</p><a href=\"/sources\">Open source →</a></div></li>", .{ index + 1, safe_source, safe_ref }) catch return mer.internalError("wiki render failed");
    }
    w.writeAll("</ol></section></article><aside class=\"reader-related\"><p class=\"eyebrow\">Connected ideas</p>") catch return mer.internalError("wiki render failed");
    for (page.backlinks) |backlink| {
        const safe_backlink = lib.ui.escape(req.allocator, backlink) catch backlink;
        w.print("<a href=\"/wiki\"><strong>{s}</strong><span>Backlink</span></a>", .{safe_backlink}) catch return mer.internalError("wiki render failed");
    }
    w.print("<div class=\"backlinks\"><small>Evidence</small><strong>{d} citations</strong><span>{d} source records</span></div></aside></div></main>", .{ page.citation_count, page.source_ids.len }) catch return mer.internalError("wiki render failed");
    return lib.ui.htmlResponse(&buf);
}

fn isFixtureSlug(slug: []const u8) bool {
    return std.mem.eql(u8, slug, "balanced-search-trees") or
        std.mem.eql(u8, slug, "graph-traversal") or
        std.mem.eql(u8, slug, "software-project-quality") or
        std.mem.eql(u8, slug, "digital-consent") or
        std.mem.eql(u8, slug, "binary-search-trees") or
        std.mem.eql(u8, slug, "amortised-analysis");
}

fn renderMissing(req: mer.Request, slug: []const u8) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const safe_slug = lib.ui.escape(req.allocator, slug) catch slug;
    buf.writer.print("<main id=\"main\" class=\"reader-page reader-missing\"><section class=\"empty-state surface\"><p class=\"eyebrow\">Knowledge wiki</p><h1>Page not generated yet</h1><p>No source-grounded article exists for <strong>{s}</strong>.</p><a class=\"button button-dark\" href=\"/wiki\">Browse connected topics</a></section></main>", .{safe_slug}) catch return mer.internalError("wiki render failed");
    return .{ .status = .not_found, .content_type = .html, .body = buf.written() };
}

fn titleForSlug(slug: []const u8) []const u8 {
    if (std.mem.eql(u8, slug, "balanced-search-trees")) return "Balanced search trees";
    if (std.mem.eql(u8, slug, "graph-traversal")) return "Graph traversal";
    if (std.mem.eql(u8, slug, "software-project-quality")) return "Software project quality";
    if (std.mem.eql(u8, slug, "digital-consent")) return "Digital consent";
    if (std.mem.eql(u8, slug, "binary-search-trees")) return "Binary search trees";
    if (std.mem.eql(u8, slug, "amortised-analysis")) return "Amortised analysis";
    return "Connected knowledge";
}
