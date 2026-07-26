const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Knowledge wiki",
    .description = "A source-grounded knowledge wiki article.",
};

const ICON_BACK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m15 18-6-6 6-6M9 12h12\"/></svg>";
const ICON_DOWNLOAD = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 3v12M7 10l5 5 5-5\"/><path d=\"M5 21h14\"/></svg>";
const ICON_LINK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M10 13a5 5 0 0 0 7.5.5l2-2a5 5 0 0 0-7-7l-1.1 1.1\"/><path d=\"M14 11a5 5 0 0 0-7.5-.5l-2 2a5 5 0 0 0 7 7l1.1-1.1\"/></svg>";
const ICON_MOON = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 3a6 6 0 1 0 9 9 9 9 0 1 1-9-9Z\"/></svg>";

pub fn render(req: mer.Request) mer.Response {
    const slug = req.param("slug") orelse "immutable-lists";
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    if (!isSafeSlug(slug)) return renderMissing(req, slug, lib.m3.isExplicitDemo(req));
    const session = lib.session.fromRequest(req);
    const use_mock = lib.m3.isExplicitDemo(req);
    const now_secs = lib.time.nowSecs();
    const enrollment_scope = req.queryParam("enrollment") orelse "";
    if (enrollment_scope.len > 0 and !safeUuid(enrollment_scope)) return mer.badRequest("invalid enrollment scope");

    if (!use_mock) {
        const result = if (enrollment_scope.len > 0) lib.backend.getEnrollmentWikiPage(req.allocator, session.token, slug, enrollment_scope) else lib.backend.getWikiPage(req.allocator, session.token, slug);
        if (result.value) |page| return renderLiveReader(req, page.value, now_secs);
        if (result.status == 404) return renderMissing(req, slug, false);
        return lib.m3.liveError(req, "Wiki page", result.status);
    }
    if (isFixtureSlug(slug)) return renderEditorialFixture(req, slug);
    const page = findPage(slug) orelse return renderMissing(req, slug, true);
    return renderMockReader(req, page, now_secs);
}

fn renderEditorialFixture(req: mer.Request, slug: []const u8) mer.Response {
    const title = titleForSlug(slug);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("wiki render failed");
    const safe_title = lib.ui.escapeSafe(req.allocator, title);
    w.print("<main id=\"main\" tabindex=\"-1\" class=\"reader-page\" data-cp-document-title=\"{s}\"><header class=\"reader-header\"><a class=\"reader-brand\" href=\"/wiki?mock=1\">", .{safe_title}) catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_BACK) catch return mer.internalError("wiki render failed");
    w.writeAll("<span class=\"cp-brand-mark\">W</span><span>Knowledge wiki<small class=\"reader-demo-note\">Synthetic demo</small></span></a><div class=\"reader-tools\"><button id=\"cp-copy-article\" type=\"button\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_LINK) catch return mer.internalError("wiki render failed");
    w.writeAll("<span>Copy link</span></button><button type=\"button\" data-cp-theme-toggle aria-label=\"Switch to dark mode\">") catch return mer.internalError("wiki render failed");
    w.writeAll(ICON_MOON) catch return mer.internalError("wiki render failed");
    w.writeAll("</button></div><a class=\"button button-dark button-small\" href=\"/chat?mock=1\">Ask about this topic</a></header><div class=\"reader-layout\"><aside class=\"reader-toc\"><p class=\"eyebrow\">On this page</p><nav aria-label=\"Article contents\"><a class=\"active\" href=\"#overview\">Overview</a><a href=\"#invariant\">The invariant</a><a href=\"#rotations\">Rotations</a><a href=\"#comparison\">AVL vs red-black</a><a href=\"#references\">References</a></nav><div><small>Source coverage</small><strong>3 connected sources</strong><span>Illustrative demo evidence</span></div></aside><article class=\"wiki-article\"><header><div class=\"article-breadcrumb\"><a href=\"/wiki?mock=1\">Wiki</a><span>/</span><a href=\"/wiki?module=CS2040S&amp;mock=1\">CS2040S</a></div><h1>") catch return mer.internalError("wiki render failed");
    w.writeAll(safe_title) catch return mer.internalError("wiki render failed");
    w.writeAll(
        \\</h1><p class="article-deck">A balanced search tree preserves the ordering of a binary search tree while controlling height so search, insertion, and deletion remain efficient.</p><div class="article-meta"><span>Updated 18 minutes ago</span><span>·</span><span>7 minute read</span><span>·</span><span>3 connected sources</span></div><div class="topic-row"><span>AVL trees</span><span>Rotations</span><span>Tree height</span></div></header>
        \\<section id="overview"><h2>Overview</h2><p>An ordinary binary search tree can become a chain when keys arrive in an unfortunate order. Its operations then fall from logarithmic to linear time. Balanced variants prevent that collapse by maintaining an additional structural invariant after every update. <sup><a href="#ref-1">1</a></sup></p><blockquote><p>Balance is not perfect symmetry. It is a rule strong enough to keep the tree shallow and cheap enough to repair locally.</p></blockquote></section>
        \\<section id="invariant"><h2>The AVL invariant</h2><p>For each node <code>v</code>, define its balance factor as the height of the left subtree minus the height of the right subtree. An AVL tree requires this value to remain in <code>{-1, 0, 1}</code>.</p><div class="concept-card"><div class="tree-sketch" aria-label="A balanced binary tree diagram"><span class="tree-node root">8</span><span class="tree-line left"></span><span class="tree-line right"></span><span class="tree-node child child-left">4</span><span class="tree-node child child-right">12</span><span class="tree-node leaf leaf-a">2</span><span class="tree-node leaf leaf-b">6</span></div><div><p class="eyebrow">Structural evidence</p><h3>Local balance controls global height.</h3><p>The smallest AVL tree of height <em>h</em> contains the smallest trees of heights <em>h−1</em> and <em>h−2</em>. This Fibonacci-like growth makes the number of nodes exponential in height.</p><a class="citation" href="#ref-2"><span>2</span>Lecture 08, p. 12</a></div></div></section>
        \\<section id="rotations"><h2>Rotations repair the path</h2><p>Insertion changes heights only along the path back to the root. At the first unbalanced node, one single or double rotation restores balance while preserving the in-order sequence.</p><h3>Single rotation</h3><ul><li>Use a right rotation for a left-left imbalance.</li><li>Use a left rotation for a right-right imbalance.</li></ul><h3>Double rotation</h3><p>When the heavy child leans in the opposite direction, rotate the child first and then the unbalanced node. The two local changes bring the middle key to the top. <sup><a href="#ref-1">1</a></sup></p><pre><code>rebalance(node):&#10;  if balance(node) &gt; 1:&#10;    rotate right or left-right&#10;  if balance(node) &lt; -1:&#10;    rotate left or right-left</code></pre></section>
        \\<section id="comparison"><h2>AVL and red-black trees</h2><div class="comparison-table" role="table" aria-label="AVL and red-black tree comparison"><div role="row"><strong role="columnheader">Property</strong><strong role="columnheader">AVL</strong><strong role="columnheader">Red-black</strong></div><div role="row"><span>Balance rule</span><span>Height difference ≤ 1</span><span>Colour and black-height rules</span></div><div role="row"><span>Lookup</span><span>Tighter height bound</span><span>Slightly looser bound</span></div><div role="row"><span>Updates</span><span>May rebalance more often</span><span>Usually fewer rotations</span></div></div><p>Choose the invariant that suits the workload. AVL trees favour lookup-heavy use; red-black trees trade a little height for cheaper frequent updates. <sup><a href="#ref-3">3</a></sup></p></section>
        \\<section id="references" class="references"><p class="eyebrow">Evidence trail</p><h2>References</h2><ol><li id="ref-1"><span>1</span><div><strong>Lecture 08 — Balanced Search Trees</strong><p>CS2040S · pages 8–21</p><a href="/sources?mock=1">Open source →</a></div></li><li id="ref-2"><span>2</span><div><strong>Tutorial 05 — Tree Height Proof</strong><p>CS2040S · question 3</p><a href="/sources?mock=1">Open source →</a></div></li><li id="ref-3"><span>3</span><div><strong>Recommended reading — Search Trees</strong><p>Section 13.3</p><a href="/sources?mock=1">Open source →</a></div></li></ol></section></article>
        \\<aside class="reader-related"><p class="eyebrow">Connected ideas</p><a href="/wiki/graph-traversal?mock=1"><strong>Tree traversal</strong><span>Neighbour topic</span></a><a href="/wiki/binary-search-trees?mock=1"><strong>Binary search trees</strong><span>Foundation</span></a><a href="/wiki/amortised-analysis?mock=1"><strong>Amortised analysis</strong><span>Needs evidence</span></a><div class="backlinks"><small>Linked from</small><strong>4 wiki articles</strong><span>2 grounded answers</span></div></aside></div></main>
    ) catch return mer.internalError("wiki render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderLiveReader(req: mer.Request, page: lib.types.WikiPageResponse, now_secs: i64) mer.Response {
    const token = lib.session.fromRequest(req).token;
    var runs: []const lib.types.ProcessingRunResponse = &.{};
    var runs_loaded = true;
    if (page.source_ids.len > 0) {
        const result = lib.backend.listProcessingRuns(req.allocator, token, page.source_ids[0], 5);
        if (result.value) |parsed| runs = parsed.value else runs_loaded = false;
    }
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
    const safe_summary = lib.ui.escapeSafe(req.allocator, page.summary);
    const safe_slug = if (isSafeSlug(page.slug)) page.slug else "";
    const when = lib.time.formatRelative(req.allocator, page.updated_at, now_secs) catch "—";
    const created = lib.time.formatRelative(req.allocator, page.created_at, now_secs) catch "—";
    const enrollment_scope = req.queryParam("enrollment") orelse "";
    const scoped_enrollment = if (safeUuid(enrollment_scope)) enrollment_scope else "";
    const wiki_path = if (scoped_enrollment.len > 0) std.fmt.allocPrint(req.allocator, "/wiki?enrollment={s}", .{scoped_enrollment}) catch "/wiki" else "/wiki";
    const chat_path = if (scoped_enrollment.len > 0) std.fmt.allocPrint(req.allocator, "/chat?enrollment={s}", .{scoped_enrollment}) catch "/chat" else "/chat";
    const wiki_href = lib.m3.demoHref(req.allocator, req, wiki_path) catch return mer.internalError("wiki render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, chat_path) catch return mer.internalError("wiki render failed");

    w.print("<main id=\"main\" tabindex=\"-1\" class=\"reader-page\" data-cp-document-title=\"{s}\"><header class=\"reader-header\"><a class=\"reader-brand\" href=\"{s}\">{s}<span class=\"cp-brand-mark\">W</span><span>Knowledge wiki</span></a><div class=\"reader-tools\"><form class=\"reader-export\" method=\"post\" action=\"/api/m3\" data-page-download data-slug=\"{s}\"><button type=\"submit\" aria-label=\"Download canonical Markdown\">{s}<span>Export</span></button><span class=\"cp-form-status\" role=\"status\" aria-live=\"polite\"></span></form><button id=\"cp-copy-article\" type=\"button\">{s}<span>Copy link</span></button><button type=\"button\" data-cp-theme-toggle aria-label=\"Switch to dark mode\">{s}</button></div><a class=\"button button-dark button-small\" href=\"{s}\">Ask about this topic</a></header><script src=\"/m3.js?v=20260721\" defer></script>", .{ safe_title, wiki_href, ICON_BACK, safe_slug, ICON_DOWNLOAD, ICON_LINK, ICON_MOON, chat_href }) catch return mer.internalError("wiki render failed");
    w.print("<div class=\"reader-layout\"><aside class=\"reader-toc\"><p class=\"eyebrow\">On this page</p><nav aria-label=\"Article contents\"><a class=\"active\" href=\"#overview\">Overview</a><a href=\"#references\">References</a></nav><div><small>Source coverage</small><strong>{d} connected sources</strong><span>No curriculum coverage score is available yet</span></div></aside><article class=\"wiki-article\"><header><div class=\"article-breadcrumb\"><a href=\"{s}\">Wiki</a><span>/</span><span>{s}</span></div><h1>{s}</h1><p class=\"article-deck\">{s}</p><div class=\"article-meta\"><span>Updated {s}</span><span>·</span><span>{d} citations</span><span>·</span><span>{d} connected sources</span></div><div class=\"topic-row\"><span>{s}</span><span>Traceable evidence</span></div></header><section id=\"overview\">", .{ page.source_ids.len, wiki_href, lib.ui.escapeSafe(req.allocator, page.page_type), safe_title, safe_summary, when, page.citation_count, page.source_ids.len, lib.ui.escapeSafe(req.allocator, page.page_type) }) catch return mer.internalError("wiki render failed");
    lib.markdown.renderMarkdown(req.allocator, w, page.markdown) catch return mer.internalError("wiki render failed");
    w.writeAll("</section><section id=\"references\" class=\"references\"><p class=\"eyebrow\">Evidence trail</p><h2>References</h2><ol>") catch return mer.internalError("wiki render failed");
    for (page.citations, 0..) |citation, index| {
        const source_href = if (safeUuid(citation.source_id)) if (scoped_enrollment.len > 0) std.fmt.allocPrint(req.allocator, "/sources?source={s}&enrollment_id={s}", .{ citation.source_id, scoped_enrollment }) catch "/sources" else std.fmt.allocPrint(req.allocator, "/sources?source={s}", .{citation.source_id}) catch "/sources" else "/sources";
        w.print("<li id=\"ref-{d}\"><span>{d}</span><div><strong>{s}</strong><p>{s}</p><blockquote>{s}</blockquote><a href=\"{s}\">Open source →</a></div></li>", .{ index + 1, index + 1, lib.ui.escapeSafe(req.allocator, citation.source_title), lib.ui.escapeSafe(req.allocator, citation.citation_ref), lib.ui.escapeSafe(req.allocator, citation.snippet), lib.ui.escapeSafe(req.allocator, source_href) }) catch return mer.internalError("wiki render failed");
    }
    w.writeAll("</ol></section></article><aside class=\"reader-related\"><p class=\"eyebrow\">Connected ideas</p>") catch return mer.internalError("wiki render failed");
    for (page.backlinks) |backlink| {
        const backlink_href = if (isSafeSlug(backlink)) if (scoped_enrollment.len > 0) std.fmt.allocPrint(req.allocator, "/wiki/{s}?enrollment={s}", .{ backlink, scoped_enrollment }) catch wiki_href else std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{backlink}) catch wiki_href else wiki_href;
        w.print("<a href=\"{s}\"><strong>{s}</strong><span>Backlink</span></a>", .{ lib.ui.escapeSafe(req.allocator, backlink_href), lib.ui.escapeSafe(req.allocator, backlink) }) catch return mer.internalError("wiki render failed");
    }
    w.print("<div class=\"backlinks\"><small>Evidence</small><strong>{d} citations</strong><span>{d} source records · created {s}</span></div></aside></div>", .{ page.citation_count, page.source_ids.len, created }) catch return mer.internalError("wiki render failed");
    if (page.source_ids.len > 0) w.print("<div class=\"cp-wiki-rebuild\"><button class=\"cp-btn cp-btn-primary\" type=\"button\" data-manual-processing-trigger data-source-id=\"{s}\">Rebuild Wiki from current source</button><span class=\"cp-form-status\" role=\"status\" tabindex=\"-1\"></span><p>The request only queues durable work. This prior valid Wiki remains open if refresh fails.</p></div>", .{lib.ui.escapeSafe(req.allocator, page.source_ids[0])}) catch return mer.internalError("wiki render failed");
    if (runs_loaded) lib.processing_ui.render(req.allocator, w, runs, "", false) catch return mer.internalError("wiki render failed") else w.writeAll("<section class=\"cp-processing-panel surface\"><h2>Wiki compilation</h2><p role=\"alert\">Refresh status is unavailable. The prior valid Wiki above is preserved.</p></section>") catch return mer.internalError("wiki render failed");
    w.writeAll("</main>") catch return mer.internalError("wiki render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderMockReader(req: mer.Request, page: lib.types.WikiPage, now_secs: i64) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("wiki render failed");
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("wiki render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, "/chat") catch return mer.internalError("wiki render failed");
    const when = lib.time.formatRelative(req.allocator, page.updated_at, now_secs) catch "—";
    const safe_title = lib.ui.escapeSafe(req.allocator, page.title);
    w.print("<main id=\"main\" tabindex=\"-1\" class=\"reader-page\" data-cp-document-title=\"{s}\"><header class=\"reader-header\"><a class=\"reader-brand\" href=\"{s}\">{s}<span class=\"cp-brand-mark\">W</span><span>Knowledge wiki<small class=\"reader-demo-note\">Synthetic demo</small></span></a><div class=\"reader-tools\"><button id=\"cp-copy-article\" type=\"button\">{s}<span>Copy link</span></button><button type=\"button\" data-cp-theme-toggle aria-label=\"Switch to dark mode\">{s}</button></div><a class=\"button button-dark button-small\" href=\"{s}\">Ask about this topic</a></header>", .{ safe_title, wiki_href, ICON_BACK, ICON_LINK, ICON_MOON, chat_href }) catch return mer.internalError("wiki render failed");
    w.print("<div class=\"reader-layout\"><aside class=\"reader-toc\"><p class=\"eyebrow\">On this page</p><nav aria-label=\"Article contents\"><a class=\"active\" href=\"#overview\">Overview</a><a href=\"#references\">References</a></nav></aside><article class=\"wiki-article\"><header><div class=\"article-breadcrumb\"><a href=\"{s}\">Wiki</a><span>/</span><span>Synthetic demo</span></div><h1>{s}</h1><p class=\"article-deck\">{s}</p><div class=\"article-meta\"><span>Updated {s}</span><span>·</span><span>{d} citations</span></div><div class=\"topic-row\">", .{ wiki_href, safe_title, lib.ui.escapeSafe(req.allocator, page.summary), when, page.citations.len }) catch return mer.internalError("wiki render failed");
    for (page.topics) |topic| w.print("<span>{s}</span>", .{lib.ui.escapeSafe(req.allocator, topic)}) catch return mer.internalError("wiki render failed");
    w.writeAll("</div></header><section id=\"overview\">") catch return mer.internalError("wiki render failed");
    lib.markdown.renderMarkdown(req.allocator, w, page.markdown) catch return mer.internalError("wiki render failed");
    w.writeAll("</section><section id=\"references\" class=\"references\"><p class=\"eyebrow\">Evidence trail</p><h2>References</h2><ol>") catch return mer.internalError("wiki render failed");
    for (page.citations, 0..) |citation, index| {
        const raw_href = lib.m3.safeSourceHref(citation.url, "/sources");
        const href = if (std.mem.startsWith(u8, raw_href, "/")) lib.m3.demoHref(req.allocator, req, raw_href) catch "/sources?mock=1" else raw_href;
        w.print("<li id=\"ref-{d}\"><span>{d}</span><div><strong>{s}</strong><p>{s}</p><a href=\"{s}\">Open source →</a></div></li>", .{ index + 1, index + 1, lib.ui.escapeSafe(req.allocator, citation.title), lib.ui.escapeSafe(req.allocator, citation.snippet), lib.ui.escapeSafe(req.allocator, href) }) catch return mer.internalError("wiki render failed");
    }
    w.writeAll("</ol></section></article><aside class=\"reader-related\"><p class=\"eyebrow\">Presentation</p><div class=\"backlinks\"><small>Access</small><strong>Anonymous demo</strong><span>Synthetic source data</span></div></aside></div></main>") catch return mer.internalError("wiki render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn findPage(slug: []const u8) ?lib.types.WikiPage {
    for (lib.mock.wiki_pages) |page| if (std.mem.eql(u8, page.slug, slug)) return page;
    return null;
}

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

fn isSafeSlug(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > 160) return false;
    for (raw) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn isFixtureSlug(slug: []const u8) bool {
    return std.mem.eql(u8, slug, "balanced-search-trees") or
        std.mem.eql(u8, slug, "graph-traversal") or
        std.mem.eql(u8, slug, "software-project-quality") or
        std.mem.eql(u8, slug, "digital-consent") or
        std.mem.eql(u8, slug, "binary-search-trees") or
        std.mem.eql(u8, slug, "amortised-analysis");
}

fn renderMissing(req: mer.Request, slug: []const u8, demo: bool) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("wiki render failed");
    const safe_slug = lib.ui.escapeSafe(req.allocator, slug);
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("wiki render failed");
    const missing_copy: []const u8 = if (demo) "No synthetic demo page exists for" else "No live wiki page has been generated for";
    w.print("<main id=\"main\" tabindex=\"-1\" class=\"reader-page reader-missing\" data-cp-document-title=\"Page not generated yet\"><section class=\"empty-state surface\"><p class=\"eyebrow\">{s}Knowledge wiki</p><h1>Page not generated yet</h1><p>{s} <strong>{s}</strong>.</p><a class=\"button button-dark\" href=\"{s}\">Browse wiki pages</a></section></main>", .{ if (demo) "Synthetic demo · " else "", missing_copy, safe_slug, wiki_href }) catch return mer.internalError("wiki render failed");
    return lib.m3.privateForSession(req, .{ .status = .not_found, .content_type = .html, .body = buf.written() });
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
