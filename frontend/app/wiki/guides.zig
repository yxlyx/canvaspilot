const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Study guides", .description = "Generate and revisit grounded study guides." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Study guides")) |response| return response;
    const demo = lib.m3.isExplicitDemo(req);
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("guides render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Grounded synthesis</p><h1 class=\"cp-page-title\">Study guides</h1><p class=\"cp-page-sub\">Build a cited guide from one clear workspace scope.</p></div></header>") catch return mer.internalError("guides render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.wiki_tabs, "guides", "Wiki", demo) catch return mer.internalError("guide tabs failed");
    if (demo) return renderDemo(req, &buf);

    const token = lib.session.fromRequest(req).token;
    const outputs = lib.backend.listOutputs(req.allocator, token, null);
    const sources = lib.backend.listSources(req.allocator, token);
    const pages = lib.backend.listWikiPages(req.allocator, token);
    if (outputs.value == null) return lib.m3.liveError(req, "Study guides", outputs.status);
    w.writeAll("<section class=\"cp-guide-toolbar\" aria-labelledby=\"guide-create\"><div><p class=\"eyebrow\">New guide</p><h2 id=\"guide-create\">Choose the evidence boundary</h2></div><form method=\"post\" action=\"/api/m3\" data-m3-form data-success=\"/wiki/guides\"><input type=\"hidden\" name=\"action\" value=\"output.create\"><input type=\"hidden\" name=\"output_type\" value=\"study_guide\"><label class=\"cp-field\"><span>Scope</span><select name=\"scope_type\" data-scope-select><option value=\"source_ids\">Source</option><option value=\"wiki_page_id\">Wiki article</option><option value=\"topic\">Topic</option></select></label><label class=\"cp-field\" data-scope-field=\"source_ids\"><span>Source</span><select name=\"source_ids\" required><option value=\"\">Choose a source</option>") catch return mer.internalError("guides render failed");
    if (sources.value) |parsed| for (parsed.value) |source| w.print("<option value=\"{s}\">{s}</option>", .{ lib.ui.escapeSafe(req.allocator, source.id), lib.ui.escapeSafe(req.allocator, source.title) }) catch return mer.internalError("guides render failed");
    w.writeAll("</select></label><label class=\"cp-field\" data-scope-field=\"wiki_page_id\" hidden><span>Wiki article</span><select name=\"wiki_page_id\" disabled required><option value=\"\">Choose an article</option>") catch return mer.internalError("guides render failed");
    if (pages.value) |parsed| for (parsed.value) |page| w.print("<option value=\"{s}\">{s}</option>", .{ lib.ui.escapeSafe(req.allocator, page.id), lib.ui.escapeSafe(req.allocator, page.title) }) catch return mer.internalError("guides render failed");
    w.writeAll("</select></label><label class=\"cp-field\" data-scope-field=\"topic\" hidden><span>Topic</span><input name=\"topic\" maxlength=\"100\" disabled required></label><label class=\"cp-field\"><span>Optional title</span><input name=\"title\" maxlength=\"300\"></label><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Generate guide</button><p class=\"cp-form-status\" role=\"status\"></p></form></section><section class=\"cp-document-ledger\" aria-labelledby=\"saved-guides\"><header><p class=\"eyebrow\">Library</p><h2 id=\"saved-guides\">Saved guides</h2></header>") catch return mer.internalError("guides render failed");
    var shown: usize = 0;
    for (outputs.value.?.value.items) |output| {
        if (!std.mem.eql(u8, output.output_type, "study_guide")) continue;
        shown += 1;
        w.print("<article><div><h3><a href=\"/wiki/guides/{s}\">{s}</a></h3><p>{s}</p></div><span class=\"cp-state status-pill\">{s}</span><strong>{d} citations</strong></article>", .{ lib.ui.escapeSafe(req.allocator, output.id), lib.ui.escapeSafe(req.allocator, output.title), lib.ui.escapeSafe(req.allocator, output.message), lib.ui.escapeSafe(req.allocator, output.status), output.citations.len }) catch return mer.internalError("guides render failed");
    }
    if (shown == 0) w.writeAll("<div class=\"cp-empty\"><div><h3>No study guides yet</h3><p>Create one from a source, article, or focused topic.</p></div></div>") catch return mer.internalError("guides render failed");
    w.writeAll("</section><script src=\"/m3.js?v=20260722\" defer></script>") catch return mer.internalError("guides render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderDemo(req: mer.Request, buf: *std.Io.Writer.Allocating) mer.Response {
    const w = &buf.writer;
    const state = req.queryParam("state") orelse "grounded";
    w.writeAll("<section class=\"cp-guide-toolbar\"><div><p class=\"eyebrow\">Synthetic guide</p><h2>Grounded before generated.</h2><p>The guide stops when the selected material cannot support it.</p></div><form method=\"get\"><input type=\"hidden\" name=\"mock\" value=\"1\"><label class=\"cp-field\"><span>Evidence state</span><select name=\"state\">") catch return mer.internalError("guides render failed");
    tryStateOption(w, "grounded", "Grounded", state) catch return mer.internalError("guides render failed");
    tryStateOption(w, "insufficient", "Insufficient evidence", state) catch return mer.internalError("guides render failed");
    tryStateOption(w, "loading", "Loading", state) catch return mer.internalError("guides render failed");
    tryStateOption(w, "error", "Error and retry", state) catch return mer.internalError("guides render failed");
    tryStateOption(w, "provider", "Provider unavailable", state) catch return mer.internalError("guides render failed");
    w.writeAll("</select></label><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Preview state</button></form></section>") catch return mer.internalError("guides render failed");
    if (std.mem.eql(u8, state, "insufficient"))
        w.writeAll("<section class=\"cp-boundary\"><p class=\"eyebrow\">Insufficient evidence</p><h2>No unsupported guide was created.</h2><p>Add another source or narrow the topic before trying again.</p><a class=\"cp-btn cp-btn-ghost\" href=\"/sources?mock=1\">Review sources</a></section>") catch return mer.internalError("guides render failed")
    else if (std.mem.eql(u8, state, "loading"))
        w.writeAll("<section class=\"cp-boundary\" aria-busy=\"true\"><p class=\"eyebrow\">Generating</p><h2>Tracing claims to their sources.</h2><p>The evidence boundary is being checked before the guide is saved.</p><button class=\"cp-btn cp-btn-primary\" type=\"button\" disabled>Generating guide</button></section>") catch return mer.internalError("guides render failed")
    else if (std.mem.eql(u8, state, "error"))
        w.writeAll("<section class=\"cp-boundary\"><p class=\"eyebrow\">Generation interrupted</p><h2>The guide was not saved.</h2><p>Your selected scope is unchanged. Retry when the provider is available.</p><a class=\"cp-btn cp-btn-primary\" href=\"/wiki/guides?mock=1&amp;state=grounded\">Retry generation</a></section>") catch return mer.internalError("guides render failed")
    else if (std.mem.eql(u8, state, "provider"))
        w.writeAll("<section class=\"cp-boundary\"><p class=\"eyebrow\">Provider unavailable</p><h2>Connect an AI provider to generate a guide.</h2><p>Your sources and saved guides remain available.</p><a class=\"cp-btn cp-btn-primary\" href=\"/settings/providers?mock=1\">Open AI provider settings</a></section>") catch return mer.internalError("guides render failed");
    w.writeAll("<section class=\"cp-document-ledger\"><header><p class=\"eyebrow\">Library</p><h2>Saved guides</h2></header>") catch return mer.internalError("guides render failed");
    const output = lib.mock.output;
    w.print("<article><div><h3><a href=\"/wiki/guides/{s}?mock=1\">{s}</a></h3><p>{s}</p></div><span class=\"cp-state status-pill\">grounded</span><strong>{d} citations</strong></article></section>", .{ lib.m3.safeId(output.id, ""), lib.ui.escapeSafe(req.allocator, output.title), lib.ui.escapeSafe(req.allocator, output.summary), output.citations.len }) catch return mer.internalError("guides render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(buf));
}

fn tryStateOption(w: *std.Io.Writer, value: []const u8, label: []const u8, selected: []const u8) !void {
    try w.print("<option value=\"{s}\"{s}>{s}</option>", .{ value, if (std.mem.eql(u8, value, selected)) " selected" else "", label });
}
