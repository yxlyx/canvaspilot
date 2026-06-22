// app/wiki/index.zig — generated wiki index for the M2 prototype.
//
// Lists generated workspace wiki pages from fixture data until the backend wiki
// compiler exposes metadata endpoints.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Wiki",
    .description = "Browse generated CanvasPilot wiki pages with citations.",
};

pub fn render(req: mer.Request) mer.Response {
    var total_citations: usize = 0;
    for (lib.mock.wiki_pages) |page| total_citations += page.citations.len;

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <div class="cp-page-title">Generated wiki</div>
        \\    <div class="cp-page-sub">Browse study pages compiled from indexed workspace sources.</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="/sources">Review sources</a>
        \\    <a class="cp-btn cp-btn-primary" href="/chat">Ask with citations</a>
        \\  </div>
        \\</header>
    ) catch return mer.internalError("wiki index render failed");

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("wiki index render failed");
    metricCard(w, "Pages", lib.mock.wiki_pages.len, "generated notes") catch return mer.internalError("wiki index render failed");
    metricCard(w, "Citations", total_citations, "source links") catch return mer.internalError("wiki index render failed");
    metricCard(w, "Sources", lib.mock.sources.len, "indexed records") catch return mer.internalError("wiki index render failed");
    metricCard(w, "Decks", lib.mock.decks.len, "practice sets") catch return mer.internalError("wiki index render failed");
    w.writeAll("</section>\n") catch return mer.internalError("wiki index render failed");

    w.writeAll(
        \\<section class="cp-card">
        \\  <div class="cp-card-title"><span>Wiki pages</span><span>prototype data</span></div>
        \\  <div class="cp-wiki-list">
    ) catch return mer.internalError("wiki index render failed");

    if (lib.mock.wiki_pages.len == 0) {
        w.writeAll("    <div class=\"cp-empty\">No wiki pages have been generated yet.</div>\n") catch return mer.internalError("wiki index render failed");
    }

    for (lib.mock.wiki_pages) |page| {
        const safe_title = lib.ui.escape(req.allocator, page.title) catch page.title;
        const safe_summary = lib.ui.escape(req.allocator, page.summary) catch page.summary;
        const href = std.fmt.allocPrint(req.allocator, "/wiki/{s}", .{page.slug}) catch "/wiki/immutable-lists";
        w.print(
            \\    <a class="cp-wiki-row" href="{s}">
            \\      <span>{s}</span>
            \\      <small>{s}</small>
            \\      <em>{d} citations</em>
            \\    </a>
        , .{ href, safe_title, safe_summary, page.citations.len }) catch return mer.internalError("wiki index render failed");
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
