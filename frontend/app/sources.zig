const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Sources",
    .description = "Search, preview, filter, and import source documents.",
};

const ICON_SEARCH = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"11\" cy=\"11\" r=\"8\"/><path d=\"m21 21-4.3-4.3\"/></svg>";
const ICON_PLUS = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 5v14M5 12h14\"/></svg>";
const ICON_GRID = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"7\" height=\"7\" x=\"3\" y=\"3\"/><rect width=\"7\" height=\"7\" x=\"14\" y=\"3\"/><rect width=\"7\" height=\"7\" x=\"3\" y=\"14\"/><rect width=\"7\" height=\"7\" x=\"14\" y=\"14\"/></svg>";
const ICON_LIST = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01\"/></svg>";
const ICON_LIBRARY = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"8\" height=\"18\" x=\"3\" y=\"3\" rx=\"1\"/><path d=\"M7 3v18\"/><path d=\"M20.4 18.9c.2.5-.1 1.1-.6 1.3l-1.9.7c-.5.2-1.1-.1-1.3-.6L11.1 5.1c-.2-.5.1-1.1.6-1.3l1.9-.7c.5-.2 1.1.1 1.3.6Z\"/></svg>";
const ICON_CHECK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"m8 12 2.5 2.5L16 9\"/></svg>";
const ICON_DASHED = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\" stroke-dasharray=\"3 3\"/></svg>";
const ICON_ALERT = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 7v6M12 17h.01\"/></svg>";
const ICON_FILTER = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6\"/></svg>";
const ICON_MORE = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"5\" cy=\"12\" r=\"1\"/><circle cx=\"12\" cy=\"12\" r=\"1\"/><circle cx=\"19\" cy=\"12\" r=\"1\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M5 12h14M13 6l6 6-6 6\"/></svg>";
const ICON_INFO = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 11v5M12 8h.01\"/></svg>";

const Source = struct {
    id: []const u8,
    title: []const u8,
    module: []const u8,
    format: []const u8,
    detail: []const u8,
    status: []const u8,
    tags: []const u8,
    updated: []const u8,
};

const sources = [_]Source{
    .{ .id = "lecture-08", .title = "Lecture 08 — Balanced Search Trees", .module = "CS2040S", .format = "PDF", .detail = "42 pages", .status = "Ready", .tags = "AVL trees · Red-black trees", .updated = "Indexed 18 min ago" },
    .{ .id = "tutorial-05", .title = "Tutorial 05 — Graph Traversal", .module = "CS2040S", .format = "PDF", .detail = "8 pages", .status = "Ready", .tags = "BFS · DFS", .updated = "Indexed yesterday" },
    .{ .id = "team-guide", .title = "Project Team Guide", .module = "CS2103T", .format = "URL", .detail = "Web page", .status = "Importing", .tags = "Collaboration", .updated = "Parsing sections" },
    .{ .id = "ethics-reader", .title = "Digital Ethics Reader", .module = "IS1108", .format = "PDF", .detail = "96 pages", .status = "Needs attention", .tags = "Consent · Platforms", .updated = "2 pages could not be read" },
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    var live_sources: ?[]const lib.types.SourceResponse = null;
    if (!use_mock) {
        const result = lib.backend.listSources(req.allocator, session.token);
        if (result.value) |parsed| {
            if (parsed.value.len > 0) live_sources = parsed.value;
        }
    }

    var ready_count: usize = 2;
    var importing_count: usize = 1;
    var attention_count: usize = 1;
    var visible_count: usize = sources.len;
    var library_count: usize = 12;
    if (live_sources) |items| {
        ready_count = 0;
        importing_count = 0;
        attention_count = 0;
        visible_count = items.len;
        library_count = items.len;
        for (items) |source| {
            const display_status = sourceDisplayStatus(source.status);
            if (std.mem.eql(u8, display_status, "Ready")) ready_count += 1 else if (std.mem.eql(u8, display_status, "Importing")) importing_count += 1 else attention_count += 1;
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    w.print(
        \\<header class="cp-page-header"><div><p class="cp-page-kicker">{d} sources · 3 modules</p><h1 class="cp-page-title">Source library</h1></div></header>
        \\<div class="sources-page"><section class="docs-workspace" aria-label="Source documents"><header class="docs-toolbar"><label class="docs-search">
    , .{library_count}) catch return mer.internalError("sources render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("sources render failed");
    w.writeAll("<input id=\"cp-source-search\" placeholder=\"Search documents, modules, or topics\" aria-label=\"Search source documents\"></label><button class=\"docs-add-button\" id=\"cp-add-source\" type=\"button\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_PLUS) catch return mer.internalError("sources render failed");
    w.print("Add source</button></header><div class=\"docs-layout\"><main class=\"docs-main\"><header class=\"docs-heading\"><div><p class=\"docs-kicker\">Semester 1 knowledge library</p><h2 id=\"cp-source-heading\">All documents</h2><span><b id=\"cp-source-count\">{d}</b> sources · previews show the indexed document</span></div><div class=\"docs-heading-actions\" aria-label=\"Document view options\"><button class=\"active\" type=\"button\" data-source-view=\"grid\" aria-label=\"Grid view\" aria-pressed=\"true\">", .{visible_count}) catch return mer.internalError("sources render failed");
    w.writeAll(ICON_GRID) catch return mer.internalError("sources render failed");
    w.writeAll("</button><button type=\"button\" data-source-view=\"list\" aria-label=\"List view\" aria-pressed=\"false\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_LIST) catch return mer.internalError("sources render failed");
    w.writeAll("</button></div></header><div class=\"source-filter-bar\" aria-label=\"Source filters\"><div class=\"source-status-tabs\" role=\"group\" aria-label=\"Import status\">") catch return mer.internalError("sources render failed");
    tryFilterCount(w, "All", visible_count, ICON_LIBRARY, true) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Ready", ready_count, ICON_CHECK, false) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Importing", importing_count, ICON_DASHED, false) catch return mer.internalError("sources render failed");
    tryFilterCount(w, "Needs attention", attention_count, ICON_ALERT, false) catch return mer.internalError("sources render failed");
    w.writeAll("</div><div class=\"source-filter-selects\">") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_FILTER) catch return mer.internalError("sources render failed");
    w.writeAll("<label><span class=\"sr-only\">Format</span><select id=\"cp-source-format\" aria-label=\"Format\"><option value=\"All\">All formats</option><option value=\"PDF\">PDF</option><option value=\"URL\">Web pages</option></select></label><label><span class=\"sr-only\">Module</span><select id=\"cp-source-module\" aria-label=\"Module\"><option value=\"All\">All modules</option><option>CS2040S</option><option>CS2103T</option><option>IS1108</option></select></label></div></div><section class=\"document-grid grid\" id=\"cp-document-grid\" aria-live=\"polite\">") catch return mer.internalError("sources render failed");
    if (live_sources) |items| {
        for (items) |source| renderLiveSource(req, w, source) catch return mer.internalError("sources render failed");
    } else {
        for (sources) |source| renderSource(req, w, source) catch return mer.internalError("sources render failed");
    }
    w.writeAll("</section><div class=\"docs-empty\" id=\"cp-source-empty\" hidden>") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_SEARCH) catch return mer.internalError("sources render failed");
    w.writeAll("<h3>No documents match</h3><p>Try another title, module, topic, status, or format.</p><button id=\"cp-clear-source-filters\" type=\"button\">Clear filters</button></div><div class=\"docs-import-note\"><span>") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_INFO) catch return mer.internalError("sources render failed");
    w.writeAll("</span><p><strong>Every answer keeps its evidence close.</strong> Imported documents are parsed into topics while preserving links from wiki claims and answers back to the source.</p><a href=\"/wiki\">Open generated wiki ") catch return mer.internalError("sources render failed");
    w.writeAll(ICON_ARROW) catch return mer.internalError("sources render failed");
    w.writeAll("</a></div></main></div></section></div>") catch return mer.internalError("sources render failed");
    renderDialogs(w) catch return mer.internalError("sources render failed");
    return lib.ui.htmlResponse(&buf);
}

fn tryFilter(w: *std.Io.Writer, label: []const u8, count: []const u8, icon: []const u8, active: bool) !void {
    try w.print("<button class=\"{s}\" type=\"button\" data-source-status=\"{s}\" aria-pressed=\"{s}\">{s}<span>{s}</span><b>{s}</b></button>", .{ if (active) "active" else "", label, if (active) "true" else "false", icon, label, count });
}

fn tryFilterCount(w: *std.Io.Writer, label: []const u8, count: usize, icon: []const u8, active: bool) !void {
    try w.print("<button class=\"{s}\" type=\"button\" data-source-status=\"{s}\" aria-pressed=\"{s}\">{s}<span>{s}</span><b>{d}</b></button>", .{ if (active) "active" else "", label, if (active) "true" else "false", icon, label, count });
}

fn sourceDisplayStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "ready") or std.mem.eql(u8, status, "indexed")) return "Ready";
    if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "indexing") or std.mem.eql(u8, status, "processing")) return "Importing";
    return "Needs attention";
}

fn sourceDisplayFormat(source_type: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(source_type, "url") or std.ascii.eqlIgnoreCase(source_type, "web") or std.ascii.eqlIgnoreCase(source_type, "web_page")) return "URL";
    return "PDF";
}

fn renderLiveSource(req: mer.Request, w: *std.Io.Writer, source: lib.types.SourceResponse) !void {
    const safe_title = lib.ui.escape(req.allocator, source.title) catch source.title;
    const safe_module = if (source.topic_tags.len > 0) (lib.ui.escape(req.allocator, source.topic_tags[0]) catch source.topic_tags[0]) else "Workspace";
    const safe_format = sourceDisplayFormat(source.source_type);
    const display_status = sourceDisplayStatus(source.status);
    const detail_raw = if (source.import_error) |err| err else source.citation_label;
    const safe_detail = lib.ui.escape(req.allocator, detail_raw) catch detail_raw;
    try w.print("<article class=\"document-card\" data-title=\"{s}\" data-module=\"{s}\" data-format=\"{s}\" data-status=\"{s}\" data-tags=\"{s}\"><header><div><h3>{s}</h3><p>{s} · {s} · {s}</p></div><button class=\"document-menu\" type=\"button\" aria-label=\"More actions for {s}\">{s}</button></header><button class=\"document-preview-button\" data-source-preview type=\"button\" aria-label=\"Preview {s}\"><div class=\"document-paper\"><div class=\"paper-running-head\"><span>{s}</span><span>INDEXED SOURCE</span></div><span class=\"paper-kicker\">KNOWLEDGE SOURCE</span><h3>{s}</h3><p class=\"paper-lede\">{s}</p><div class=\"paper-rule\"></div><div class=\"scan-lines\"><i></i><i></i><i></i><i></i></div><span class=\"paper-page\">01</span></div></button><footer><div><span class=\"status-pill status-{s}\">{s}</span><span class=\"document-tags\">{s}</span></div><div><button data-source-preview type=\"button\">Preview</button><a href=\"/wiki\">Wiki {s}</a></div></footer></article>", .{ safe_title, safe_module, safe_format, display_status, safe_detail, safe_title, safe_module, safe_format, safe_detail, safe_title, ICON_MORE, safe_title, safe_module, safe_title, safe_detail, if (std.mem.eql(u8, display_status, "Ready")) "good" else if (std.mem.eql(u8, display_status, "Importing")) "info" else "warn", display_status, safe_detail, ICON_ARROW });
}

fn renderSource(req: mer.Request, w: *std.Io.Writer, source: Source) !void {
    const safe_title = lib.ui.escape(req.allocator, source.title) catch source.title;
    try w.print("<article class=\"document-card\" data-title=\"{s}\" data-module=\"{s}\" data-format=\"{s}\" data-status=\"{s}\" data-tags=\"{s}\"><header><div><h3>{s}</h3><p>{s} · {s} · {s} · {s}</p></div><button class=\"document-menu\" type=\"button\" aria-label=\"More actions for {s}\">{s}</button></header><button class=\"document-preview-button\" data-source-preview type=\"button\" aria-label=\"Preview {s}\">", .{ safe_title, source.module, source.format, source.status, source.tags, safe_title, source.module, source.format, source.detail, source.updated, safe_title, ICON_MORE, safe_title });
    try renderPaper(w, source.id);
    try w.print("</button><footer><div><span class=\"status-pill status-{s}\">{s}</span><span class=\"document-tags\">{s}</span></div><div><button data-source-preview type=\"button\">Preview</button><a href=\"/wiki\">Wiki {s}</a></div></footer></article>", .{ if (std.mem.eql(u8, source.status, "Ready")) "good" else if (std.mem.eql(u8, source.status, "Importing")) "info" else "warn", source.status, source.tags, ICON_ARROW });
}

fn renderPaper(w: *std.Io.Writer, id: []const u8) !void {
    if (std.mem.eql(u8, id, "lecture-08")) {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>CS2040S</span><span>COURSE NOTES</span></div><h3>Balanced Search Trees</h3><p class=\"paper-lede\">Maintaining logarithmic search through local structural invariants.</p><div class=\"paper-rule\"></div><h4>8.2 The AVL invariant</h4><p>For each node, the height of the left and right subtrees differs by at most one.</p><div class=\"mini-tree\"><i class=\"tree-edge edge-left\"></i><i class=\"tree-edge edge-right\"></i><b class=\"tree-point root-point\">8</b><b class=\"tree-point left-point\">4</b><b class=\"tree-point right-point\">12</b></div><div class=\"paper-note\"><strong>Key idea</strong><span>Rotations restore balance without changing the in-order sequence.</span></div><span class=\"paper-page\">01</span></div>");
    } else if (std.mem.eql(u8, id, "tutorial-05")) {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>CS2040S</span><span>COURSE NOTES</span></div><h3>Graph Traversal</h3><p class=\"paper-lede\">Tutorial 05 · Breadth-first and depth-first search</p><div class=\"paper-rule\"></div><h4>Problem 1 — Reachability</h4><p>Trace the frontier after each step, beginning at vertex A.</p><div class=\"graph-path\"><b>A</b><i></i><b>B</b><i></i><b>D</b><i></i><b>F</b></div><ol class=\"paper-steps\"><li>Mark the starting vertex.</li><li>Visit every unmarked neighbour.</li><li>Record the predecessor edge.</li></ol><span class=\"paper-page\">01</span></div>");
    } else if (std.mem.eql(u8, id, "team-guide")) {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>CS2103T</span><span>REFERENCE</span></div><span class=\"paper-kicker\">PROJECT HANDBOOK</span><h3>Architecture &amp;<br>Team Guide</h3><p class=\"paper-lede\">Working agreements for a maintainable software project.</p><div class=\"paper-rule\"></div><div class=\"guide-columns\"><div><strong>Decide</strong><span>Record context and trade-offs.</span></div><div><strong>Review</strong><span>Keep changes small and legible.</span></div></div><h4>Definition of done</h4><div class=\"check-line\">✓ Tests explain the behaviour</div><div class=\"check-line\">✓ Documentation stays current</div><span class=\"paper-page\">01</span></div>");
    } else {
        try w.writeAll("<div class=\"document-paper\"><div class=\"paper-running-head\"><span>IS1108</span><span>COURSE NOTES</span></div><span class=\"paper-kicker\">IS1108 READER</span><h3>Meaningful Consent</h3><p class=\"paper-lede\">Agency, information asymmetry, and platform power.</p><div class=\"paper-rule\"></div><blockquote>Consent is meaningful only when refusal is understandable, accessible, and free from penalty.</blockquote><h4>Questions for analysis</h4><ul class=\"paper-list\"><li>Is the choice informed?</li><li>Can it be reversed?</li><li>Who benefits from the default?</li></ul><span class=\"paper-page\">01</span></div>");
    }
}

fn renderDialogs(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<div class="modal-backdrop document-preview-backdrop" id="cp-source-preview-modal" hidden><section class="document-preview-modal" role="dialog" aria-modal="true" aria-labelledby="cp-preview-title"><button class="preview-close" type="button" data-close-source-modal aria-label="Close document preview">×</button><div class="preview-document-stage"><div class="document-paper expanded"><span class="paper-kicker">SOURCE PREVIEW</span><h3 id="cp-preview-paper-title">Balanced Search Trees</h3><p class="paper-lede">Indexed evidence with preserved structure and citation anchors.</p><div class="paper-rule"></div><div class="scan-lines"><i></i><i></i><i></i><i></i></div></div></div><aside><p class="eyebrow">Source preview</p><h2 id="cp-preview-title">Source</h2><p id="cp-preview-detail">Course material</p><span class="status-pill status-good" id="cp-preview-status">Ready</span><dl><div><dt>Evidence</dt><dd>4 linked wiki claims</dd></div><div><dt>Traceability</dt><dd>Preserved</dd></div></dl><a class="button button-dark" href="/wiki">Open connected wiki →</a></aside></section></div>
        \\<div class="modal-backdrop" id="cp-add-source-modal" hidden><section class="source-modal surface" role="dialog" aria-modal="true" aria-labelledby="cp-add-source-title"><button class="modal-close" type="button" data-close-source-modal aria-label="Close add source dialog">×</button><p class="eyebrow">Add evidence</p><h2 id="cp-add-source-title">Bring in a course source.</h2><p>Add a public course resource and begin parsing it into traceable evidence.</p><form id="cp-add-source-form"><div class="field"><label for="cp-new-source-title">Source title</label><input id="cp-new-source-title" name="title" placeholder="e.g. Lecture 09 — Hash Tables" required></div><div class="field"><label for="cp-new-source-url">Public link</label><input id="cp-new-source-url" name="url" type="url" placeholder="https://..." required></div><div class="field"><label for="cp-new-source-module">Module</label><select id="cp-new-source-module" name="module"><option>CS2040S Data Structures</option><option>CS2103T Software Engineering</option><option>IS1108 Digital Ethics</option></select></div><button class="button button-dark" type="submit">Add and begin parsing</button></form></section></div>
    );
}
