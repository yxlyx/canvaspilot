const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Outputs", .description = "Preview cited outputs and grounding boundaries." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Outputs")) |response| return response;
    if (!lib.m3.isExplicitDemo(req)) return renderLive(req);
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
    lib.m3.demoMarker(req, w) catch return mer.internalError("outputs render failed");
    const providers_href = lib.m3.demoHref(req.allocator, req, "/settings/providers") catch return mer.internalError("outputs render failed");
    w.print(
        \\<header class="cp-page-header wb-m3-output-header"><div><p class="cp-page-kicker">Synthetic demo</p><h1 class="cp-page-title">Cited outputs</h1><p class="cp-page-sub">Choose source and wiki context, then inspect the explicit grounding boundary.</p></div><div class="cp-page-actions"><a class="cp-btn cp-btn-ghost button button-secondary" href="{s}">Provider settings</a></div></header>
    , .{providers_href}) catch return mer.internalError("outputs render failed");
    w.print(
        \\<section class="cp-card surface wb-m3-composer"><form class="cp-selector-grid wb-m3-selector" method="get"><input type="hidden" name="mock" value="1">
        \\<label class="cp-field"><span>Source</span><select name="source"><option value="demo-source-lecture"{s}>Synthetic lecture notes</option><option value="demo-source-lab"{s}>Synthetic lab brief</option></select></label>
        \\<label class="cp-field"><span>Wiki context</span><select name="wiki"><option value="demo-wiki-streams"{s}>Immutable lists and streams</option><option value="demo-wiki-lab"{s}>Lab 6 checklist</option></select></label>
        \\<label class="cp-field"><span>Preview state</span><select name="state"><option value="grounded"{s}>Grounded result</option><option value="insufficient"{s}>Insufficient context</option><option value="empty"{s}>Empty selection</option><option value="loading"{s}>Loading</option></select></label>
        \\<button class="cp-btn cp-btn-primary button button-dark" type="submit">Preview synthetic state</button></form>
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
            \\<section class="cp-card surface notice cp-boundary wb-m3-boundary" aria-labelledby="boundary-title"><div class="cp-demo-label cp-warning-label">Insufficient context</div><h2 id="boundary-title">No cited output generated</h2><p>The selected material does not contain enough support for a grounded summary. Add sources or choose a narrower question; WikiBase will not invent an answer.</p><a href="/outputs?mock=1">Return to grounded example</a></section>
        ) catch return mer.internalError("outputs render failed");
    } else if (std.mem.eql(u8, state, "empty")) {
        w.writeAll("<section class=\"cp-card surface cp-empty wb-m3-empty\"><h2>Synthetic empty-state preview</h2><p>A live request with no source or wiki selection would stop here instead of producing an uncited output.</p></section>") catch return mer.internalError("outputs render failed");
    } else if (std.mem.eql(u8, state, "loading")) {
        w.writeAll("<section class=\"cp-card surface notice notice-info cp-unavailable wb-m3-loading\"><h2>Synthetic loading-state preview</h2><p>A live request would remain pending here until the backend returns a grounded or boundary response. No request is running in this static preview.</p></section>") catch return mer.internalError("outputs render failed");
    } else {
        const output = lib.mock.output;
        const title = lib.ui.escapeSafe(req.allocator, output.title);
        const summary = lib.ui.escapeSafe(req.allocator, source_summary);
        w.print("<article class=\"cp-card surface cp-output wb-m3-output-reader\"><div class=\"cp-card-title\"><h2>{s}</h2><span>{s}</span></div><p class=\"cp-muted-copy\">Preview source: {s} · Wiki context: {s}</p><p>{s}</p><h3>Citations</h3><ol class=\"cp-citation-list wb-m3-citation-list\">", .{ title, @tagName(output.boundary), source_name, wiki_name, summary }) catch return mer.internalError("outputs render failed");
        for (output.citations) |citation| {
            if (!std.mem.eql(u8, citation.source_id, source_id)) continue;
            const source = lib.ui.escapeSafe(req.allocator, citation.source_title);
            const location = lib.ui.escapeSafe(req.allocator, citation.location);
            const snippet = lib.ui.escapeSafe(req.allocator, citation.snippet);
            w.print("<li class=\"cp-citation-card surface wb-m3-citation\"><strong>{s}</strong><small>{s}</small><p>{s}</p></li>", .{ source, location, snippet }) catch return mer.internalError("outputs render failed");
        }
        w.writeAll("</ol><a class=\"cp-btn cp-btn-ghost button button-secondary\" href=\"/outputs/demo-output-streams-summary?mock=1\">Open full output</a></article>") catch return mer.internalError("outputs render failed");
    }
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn selected(actual: []const u8, expected: []const u8) []const u8 {
    return if (std.mem.eql(u8, actual, expected)) " selected" else "";
}

fn renderLive(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const raw_cursor = req.queryParam("cursor");
    const cursor: ?[]const u8 = if (raw_cursor) |value| if (lib.m3.safeId(value, "").len > 0) value else null else null;
    const outputs = lib.backend.listOutputs(req.allocator, session.token, cursor);
    if (outputs.value == null) return lib.m3.liveError(req, "Cited outputs", outputs.status);
    const sources = lib.backend.listSources(req.allocator, session.token);
    const pages = lib.backend.listWikiPages(req.allocator, session.token);
    if (sources.status == 401 or pages.status == 401) return lib.m3.liveError(req, "Cited outputs", 401);
    const source_available = if (sources.value) |parsed| parsed.value.len > 0 else false;
    const page_available = if (pages.value) |parsed| parsed.value.len > 0 else false;
    const initial_scope: []const u8 = if (source_available) "source_ids" else if (page_available) "wiki_page_id" else "topic";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.writeAll("<header class=\"cp-page-header wb-m3-output-header\"><div><h1 class=\"cp-page-title\">Cited study outputs</h1><p class=\"cp-page-sub\">Generate grounded summaries, outlines, or study guides from exactly one workspace scope.</p></div></header>" ++
        "<section class=\"cp-card surface wb-m3-composer\" aria-labelledby=\"generate-title\"><h2 id=\"generate-title\">Create output</h2><form id=\"cp-output-form\" class=\"cp-selector-grid wb-m3-selector\" method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"/outputs\">" ++
        "<input type=\"hidden\" name=\"action\" value=\"output.create\"><label class=\"cp-field\"><span>Output type</span><select name=\"output_type\"><option value=\"summary\">Summary</option><option value=\"outline\">Outline</option><option value=\"study_guide\">Study guide</option></select></label>" ++
        "<label class=\"cp-field\"><span>Scope type</span><select name=\"scope_type\" data-scope-select>") catch return mer.internalError("outputs render failed");
    w.print("<option value=\"source_ids\"{s}{s}>Sources</option><option value=\"wiki_page_id\"{s}{s}>Wiki page</option><option value=\"topic\"{s}>Topic</option></select></label><label class=\"cp-field\" data-scope-field=\"source_ids\"{s}><span>Source</span><select name=\"source_ids\" required{s}><option value=\"\">Choose a source</option>", .{ if (source_available) "" else " disabled", selected(initial_scope, "source_ids"), if (page_available) "" else " disabled", selected(initial_scope, "wiki_page_id"), selected(initial_scope, "topic"), if (std.mem.eql(u8, initial_scope, "source_ids")) "" else " hidden", if (std.mem.eql(u8, initial_scope, "source_ids")) "" else " disabled" }) catch return mer.internalError("outputs render failed");
    if (sources.value) |parsed| for (parsed.value) |source| w.print("<option value=\"{s}\">{s}</option>", .{ lib.ui.escapeSafe(req.allocator, source.id), lib.ui.escapeSafe(req.allocator, source.title) }) catch return mer.internalError("outputs render failed");
    w.print("</select></label><label class=\"cp-field\" data-scope-field=\"wiki_page_id\"{s}><span>Wiki page</span><select name=\"wiki_page_id\" required{s}><option value=\"\">Choose a page</option>", .{ if (std.mem.eql(u8, initial_scope, "wiki_page_id")) "" else " hidden", if (std.mem.eql(u8, initial_scope, "wiki_page_id")) "" else " disabled" }) catch return mer.internalError("outputs render failed");
    if (pages.value) |parsed| for (parsed.value) |page| w.print("<option value=\"{s}\">{s}</option>", .{ lib.ui.escapeSafe(req.allocator, page.id), lib.ui.escapeSafe(req.allocator, page.title) }) catch return mer.internalError("outputs render failed");
    w.print("</select></label><label class=\"cp-field\" data-scope-field=\"topic\"{s}><span>Topic</span><input name=\"topic\" maxlength=\"100\" autocomplete=\"off\" required{s}></label><label class=\"cp-field\"><span>Optional title</span><input name=\"title\" maxlength=\"300\"></label><button class=\"cp-btn cp-btn-primary button button-dark\" type=\"submit\">Generate cited output</button><p class=\"cp-form-status\" role=\"status\" aria-live=\"polite\" tabindex=\"-1\"></p></form>", .{ if (std.mem.eql(u8, initial_scope, "topic")) "" else " hidden", if (std.mem.eql(u8, initial_scope, "topic")) "" else " disabled" }) catch return mer.internalError("outputs render failed");
    if (sources.value == null) w.writeAll("<p class=\"cp-unavailable wb-m3-unavailable\" role=\"alert\">Sources are unavailable. Source scope is disabled; topic and available wiki scopes still work.</p>") catch return mer.internalError("outputs render failed") else if (!source_available) w.writeAll("<p class=\"cp-muted-copy\">No sources are available, so source scope is disabled.</p>") catch return mer.internalError("outputs render failed");
    if (pages.value == null) w.writeAll("<p class=\"cp-unavailable wb-m3-unavailable\" role=\"alert\">Wiki pages are unavailable. Wiki scope is disabled; topic and available source scopes still work.</p>") catch return mer.internalError("outputs render failed") else if (!page_available) w.writeAll("<p class=\"cp-muted-copy\">No wiki pages are available, so wiki scope is disabled.</p>") catch return mer.internalError("outputs render failed");
    w.writeAll("</section><section class=\"wb-m3-saved-outputs\" aria-labelledby=\"saved-title\"><h2 id=\"saved-title\">Saved outputs</h2><div class=\"cp-list-grid wb-m3-output-grid\">") catch return mer.internalError("outputs render failed");
    if (outputs.value.?.value.items.len == 0) w.writeAll("<div class=\"cp-empty wb-m3-empty\"><h3>No outputs yet</h3><p>Choose one scope above to create the first output.</p></div>") catch return mer.internalError("outputs render failed");
    for (outputs.value.?.value.items[0..@min(outputs.value.?.value.items.len, 20)]) |output| {
        const boundary = if (std.mem.eql(u8, output.status, "insufficient_evidence")) "Insufficient evidence" else if (std.mem.eql(u8, output.status, "provider_unavailable")) "Provider unavailable" else output.status;
        w.print("<article class=\"cp-card surface wb-m3-output-card\"><div class=\"cp-card-title\"><h3><a href=\"/outputs/{s}\">{s}</a></h3><span class=\"cp-state status-pill wb-m3-status\">{s}</span></div><p>{s}</p><p class=\"cp-muted-copy\">{s} · {d} grounded citation(s)</p></article>", .{ lib.ui.escapeSafe(req.allocator, output.id), lib.ui.escapeSafe(req.allocator, output.title), lib.ui.escapeSafe(req.allocator, boundary), lib.ui.escapeSafe(req.allocator, output.message), lib.ui.escapeSafe(req.allocator, output.output_type), output.citations.len }) catch return mer.internalError("outputs render failed");
    }
    w.writeAll("</div></section><nav class=\"cp-filter-row filter-row wb-m3-pagination\" aria-label=\"Output pages\">") catch return mer.internalError("outputs render failed");
    if (outputs.value.?.value.next_cursor) |next| w.print("<a class=\"button button-secondary button-small\" href=\"/outputs?cursor={s}\">Next</a>", .{lib.ui.escapeSafe(req.allocator, next)}) catch return mer.internalError("outputs render failed");
    w.writeAll("</nav><script src=\"/m3.js?v=20260721\" defer></script>") catch return mer.internalError("outputs render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}
