const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Outputs", .description = "Preview cited outputs and grounding boundaries." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Outputs")) |response| return response;
    const insufficient = if (req.queryParam("state")) |state| std.mem.eql(u8, state, "insufficient") else false;
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll(
        \\<header class="cp-page-header"><div><h1 class="cp-page-title">Cited outputs</h1><p class="cp-page-sub">Choose source and wiki context, then inspect the explicit grounding boundary.</p></div><div class="cp-page-actions"><a class="cp-btn cp-btn-ghost" href="/settings/providers?mock=1">Provider settings</a></div></header>
    ) catch return mer.internalError("outputs render failed");
    lib.m3.demoBanner(w) catch return mer.internalError("outputs render failed");
    w.writeAll(
        \\<section class="cp-card"><form class="cp-selector-grid" method="get"><input type="hidden" name="mock" value="1">
        \\<label class="cp-field"><span>Source</span><select name="source"><option>Synthetic lecture notes</option><option>Synthetic lab brief</option></select></label>
        \\<label class="cp-field"><span>Wiki page</span><select name="wiki"><option>Immutable lists and streams</option></select></label>
        \\<button class="cp-btn cp-btn-primary" type="button" disabled>Generate output</button></form>
        \\<p class="cp-muted-copy">Generation is disabled in demo and remains unavailable without provider and output backend contracts.</p></section>
    ) catch return mer.internalError("outputs render failed");
    if (insufficient) {
        w.writeAll(
            \\<section class="cp-card cp-boundary" aria-labelledby="boundary-title"><div class="cp-demo-label cp-warning-label">Insufficient context</div><h2 id="boundary-title">No cited output generated</h2><p>The selected material does not contain enough support for a grounded summary. Add sources or choose a narrower question; WikiBase will not invent an answer.</p><a href="/outputs?mock=1">Return to grounded example</a></section>
        ) catch return mer.internalError("outputs render failed");
    } else {
        const output = lib.mock.output;
        const title = lib.ui.escape(req.allocator, output.title) catch output.title;
        const summary = lib.ui.escape(req.allocator, output.summary) catch output.summary;
        const filename = lib.m3.safeExportFilename(req.allocator, output.title) catch "wikibase-export.md";
        w.print("<article class=\"cp-card cp-output\"><div class=\"cp-card-title\"><h2>{s}</h2><span>{s}</span></div><p>{s}</p><h3>Citations</h3><ol class=\"cp-citation-list\">", .{ title, @tagName(output.boundary), summary }) catch return mer.internalError("outputs render failed");
        for (output.citations) |citation| {
            const source = lib.ui.escape(req.allocator, citation.source_title) catch citation.source_title;
            const location = lib.ui.escape(req.allocator, citation.location) catch citation.location;
            const snippet = lib.ui.escape(req.allocator, citation.snippet) catch citation.snippet;
            w.print("<li class=\"cp-citation-card\"><strong>{s}</strong><small>{s}</small><p>{s}</p></li>", .{ source, location, snippet }) catch return mer.internalError("outputs render failed");
        }
        w.print("</ol><button class=\"cp-btn cp-btn-ghost\" type=\"button\" disabled aria-describedby=\"export-note\">Export {s}</button><p id=\"export-note\" class=\"cp-muted-copy\">Backend export is unavailable; no download is created.</p></article>", .{filename}) catch return mer.internalError("outputs render failed");
    }
    return lib.ui.htmlResponse(&buf);
}
