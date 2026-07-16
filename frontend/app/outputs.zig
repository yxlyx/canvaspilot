const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Outputs", .description = "Preview cited outputs and grounding boundaries." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Outputs")) |response| return response;
    const requested_state = req.queryParam("state") orelse "grounded";
    const state: []const u8 = if (std.mem.eql(u8, requested_state, "insufficient") or std.mem.eql(u8, requested_state, "empty") or std.mem.eql(u8, requested_state, "loading")) requested_state else "grounded";
    const requested_source_id = req.queryParam("source") orelse "demo-source-lecture";
    const source_id: []const u8 = if (std.mem.eql(u8, requested_source_id, "demo-source-lab")) "demo-source-lab" else "demo-source-lecture";
    const source_name: []const u8 = if (std.mem.eql(u8, source_id, "demo-source-lab")) "Synthetic lab brief" else "Synthetic lecture notes";
    const requested_wiki_id = req.queryParam("wiki") orelse "demo-wiki-streams";
    const wiki_id: []const u8 = if (std.mem.eql(u8, requested_wiki_id, "demo-wiki-lab")) "demo-wiki-lab" else "demo-wiki-streams";
    const wiki_name: []const u8 = if (std.mem.eql(u8, wiki_id, "demo-wiki-lab")) "Lab 6 checklist" else "Immutable lists and streams";
    const source_summary: []const u8 = if (std.mem.eql(u8, source_id, "demo-source-lab"))
        "The synthetic lab brief supports the claim that a stream computes its next element only when requested."
    else
        "The synthetic lecture notes support the claim that immutable operations return a new value instead of changing the existing list.";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const providers_href = lib.m3.demoHref(req.allocator, req, "/settings/providers") catch return mer.internalError("outputs render failed");
    w.print(
        \\<header class="cp-page-header"><div><h1 class="cp-page-title">Cited outputs</h1><p class="cp-page-sub">Choose source and wiki context, then inspect the explicit grounding boundary.</p></div><div class="cp-page-actions"><a class="cp-btn cp-btn-ghost" href="{s}">Provider settings</a></div></header>
    , .{providers_href}) catch return mer.internalError("outputs render failed");
    lib.m3.demoBanner(req, w) catch return mer.internalError("outputs render failed");
    w.print(
        \\<section class="cp-card"><form class="cp-selector-grid" method="get"><input type="hidden" name="mock" value="1">
        \\<label class="cp-field"><span>Source</span><select name="source"><option value="demo-source-lecture"{s}>Synthetic lecture notes</option><option value="demo-source-lab"{s}>Synthetic lab brief</option></select></label>
        \\<label class="cp-field"><span>Wiki context</span><select name="wiki"><option value="demo-wiki-streams"{s}>Immutable lists and streams</option><option value="demo-wiki-lab"{s}>Lab 6 checklist</option></select></label>
        \\<label class="cp-field"><span>Preview state</span><select name="state"><option value="grounded"{s}>Grounded result</option><option value="insufficient"{s}>Insufficient context</option><option value="empty"{s}>Empty selection</option><option value="loading"{s}>Loading</option></select></label>
        \\<button class="cp-btn cp-btn-primary" type="submit">Preview synthetic state</button></form>
        \\<p class="cp-muted-copy">This form changes labelled synthetic preview states only. Live generation remains unavailable until provider and output backend contracts land.</p></section>
    , .{
        selected(source_id, "demo-source-lecture"),
        selected(source_id, "demo-source-lab"),
        selected(wiki_id, "demo-wiki-streams"),
        selected(wiki_id, "demo-wiki-lab"),
        selected(state, "grounded"),
        selected(state, "insufficient"),
        selected(state, "empty"),
        selected(state, "loading"),
    }) catch return mer.internalError("outputs render failed");
    if (std.mem.eql(u8, state, "insufficient")) {
        w.writeAll(
            \\<section class="cp-card cp-boundary" aria-labelledby="boundary-title"><div class="cp-demo-label cp-warning-label">Insufficient context</div><h2 id="boundary-title">No cited output generated</h2><p>The selected material does not contain enough support for a grounded summary. Add sources or choose a narrower question; WikiBase will not invent an answer.</p><a href="/outputs?mock=1">Return to grounded example</a></section>
        ) catch return mer.internalError("outputs render failed");
    } else if (std.mem.eql(u8, state, "empty")) {
        w.writeAll("<section class=\"cp-card cp-empty\"><h2>Synthetic empty-state preview</h2><p>A live request with no source or wiki selection would stop here instead of producing an uncited output.</p></section>") catch return mer.internalError("outputs render failed");
    } else if (std.mem.eql(u8, state, "loading")) {
        w.writeAll("<section class=\"cp-card cp-unavailable\"><h2>Synthetic loading-state preview</h2><p>A live request would remain pending here until the backend returns a grounded or boundary response. No request is running in this static preview.</p></section>") catch return mer.internalError("outputs render failed");
    } else {
        const output = lib.mock.output;
        const title = lib.ui.escapeSafe(req.allocator, output.title);
        const summary = lib.ui.escapeSafe(req.allocator, source_summary);
        const filename = lib.m3.safeExportFilename(req.allocator, output.title) catch "wikibase-export.md";
        w.print("<article class=\"cp-card cp-output\"><div class=\"cp-card-title\"><h2>{s}</h2><span>{s}</span></div><p class=\"cp-muted-copy\">Preview source: {s} · Wiki context: {s}</p><p>{s}</p><h3>Citations</h3><ol class=\"cp-citation-list\">", .{ title, @tagName(output.boundary), source_name, wiki_name, summary }) catch return mer.internalError("outputs render failed");
        for (output.citations) |citation| {
            if (!std.mem.eql(u8, citation.source_id, source_id)) continue;
            const source = lib.ui.escapeSafe(req.allocator, citation.source_title);
            const location = lib.ui.escapeSafe(req.allocator, citation.location);
            const snippet = lib.ui.escapeSafe(req.allocator, citation.snippet);
            w.print("<li class=\"cp-citation-card\"><strong>{s}</strong><small>{s}</small><p>{s}</p></li>", .{ source, location, snippet }) catch return mer.internalError("outputs render failed");
        }
        w.print("</ol><button class=\"cp-btn cp-btn-ghost\" type=\"button\" aria-disabled=\"true\" aria-describedby=\"export-note\">Export {s}</button><p id=\"export-note\" class=\"cp-muted-copy\">Backend export is unavailable; no download is created.</p></article>", .{filename}) catch return mer.internalError("outputs render failed");
    }
    return lib.ui.htmlResponse(&buf);
}

fn selected(actual: []const u8, expected: []const u8) []const u8 {
    return if (std.mem.eql(u8, actual, expected)) " selected" else "";
}
