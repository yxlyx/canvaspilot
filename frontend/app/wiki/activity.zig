const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Activity", .description = "Review durable content and learning evidence." };

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.gate(req, "Activity")) |response| return response;
    const use_mock = lib.m3.isExplicitDemo(req);
    const selected = req.queryParam("type") orelse "all";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("activity render failed");
    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Durable workspace record</p><h1 class=\"cp-page-title\">Activity</h1><p class=\"cp-page-sub\">Content changes, reviewed evidence, and generated study material in one chronological ledger.</p></div></header>") catch return mer.internalError("activity render failed");
    lib.navigation.renderTabs(req.allocator, w, &lib.navigation.wiki_tabs, "activity", "Wiki", use_mock) catch return mer.internalError("activity tabs failed");
    w.writeAll("<nav class=\"cp-filter-row wb-m3-history-filters\" aria-label=\"Activity filters\">") catch return mer.internalError("activity render failed");
    tryFilter(req, w, "All", "all", selected, use_mock) catch return mer.internalError("activity render failed");
    tryFilter(req, w, "Content", "content", selected, use_mock) catch return mer.internalError("activity render failed");
    tryFilter(req, w, "Evidence", "evidence", selected, use_mock) catch return mer.internalError("activity render failed");
    tryFilter(req, w, "Study material", "study_guides", selected, use_mock) catch return mer.internalError("activity render failed");
    w.writeAll("</nav><ol class=\"cp-activity-ledger\">") catch return mer.internalError("activity render failed");
    var shown: usize = 0;
    if (use_mock) {
        for (lib.mock.history_changes) |entry| {
            if (!std.mem.eql(u8, selected, "all") and !std.mem.eql(u8, selected, "content")) continue;
            shown += 1;
            w.print("<li><article class=\"wb-m3-history-card\"><time>{s}</time><div><p class=\"eyebrow\">Content</p><h2>{s}</h2><p>{s}</p><details class=\"cp-activity-diff\"><summary>Review bounded diff</summary><pre aria-label=\"Unified diff\">", .{ lib.ui.escapeSafe(req.allocator, entry.changed_at), lib.ui.escapeSafe(req.allocator, entry.subject_title), lib.ui.escapeSafe(req.allocator, entry.summary) }) catch return mer.internalError("activity render failed");
            for (entry.diff) |line| w.print("<span class=\"cp-diff-{s}\">{s}</span>\n", .{ @tagName(line.kind), lib.ui.escapeSafe(req.allocator, line.text) }) catch return mer.internalError("activity render failed");
            w.writeAll("</pre></details></div></article></li>") catch return mer.internalError("activity render failed");
        }
        if (std.mem.eql(u8, selected, "all") or std.mem.eql(u8, selected, "evidence")) {
            shown += 1;
            w.writeAll("<li><article class=\"wb-m3-history-card\"><time>2026-05-17T18:25:00Z</time><div><p class=\"eyebrow\">Flashcard review</p><h2>Balanced trees evidence recorded</h2><p>Reviewed 8 cards with 75% recall; the result now contributes to the topic estimate.</p></div></article></li>") catch return mer.internalError("activity render failed");
        }
        if (std.mem.eql(u8, selected, "all") or std.mem.eql(u8, selected, "study_guides")) {
            shown += 1;
            w.writeAll("<li><article class=\"wb-m3-history-card\"><time>2026-05-16T11:10:00Z</time><div><p class=\"eyebrow\">Study guide</p><h2>AVL rotations revision guide</h2><p>Generated from three indexed sources with citations retained.</p></div></article></li>") catch return mer.internalError("activity render failed");
        }
    } else {
        const result = lib.backend.activity(req.allocator, lib.session.fromRequest(req).token);
        const entries = if (result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Activity", result.status);
        for (entries) |entry| {
            if (!std.mem.eql(u8, selected, "all") and !std.mem.eql(u8, selected, entry.category)) continue;
            shown += 1;
            const href = lib.m3.safeInternalHref(entry.href, "/wiki/activity");
            w.print("<li><article class=\"wb-m3-history-card\"><time>{s}</time><div><p class=\"eyebrow\">{s}</p><h2><a href=\"{s}\">{s}</a></h2><p>{s}</p></div></article></li>", .{ lib.ui.escapeSafe(req.allocator, entry.created_at), eventLabel(entry.event_type), lib.ui.escapeSafe(req.allocator, href), lib.ui.escapeSafe(req.allocator, entry.title), lib.ui.escapeSafe(req.allocator, entry.summary) }) catch return mer.internalError("activity render failed");
        }
    }
    if (shown == 0) w.writeAll("<li class=\"cp-empty\"><div><h2>No activity in this view</h2><p>Durable changes and reviewed evidence will appear here.</p></div></li>") catch return mer.internalError("activity render failed");
    w.writeAll("</ol>") catch return mer.internalError("activity render failed");
    if (!use_mock) if (req.queryParam("page")) |page_id| if (std.mem.eql(u8, page_id, lib.m3.safeId(page_id, ""))) renderRevisions(req, w, page_id) catch return mer.internalError("revision render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn eventLabel(event_type: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "study_guide")) return "Study guide";
    if (std.mem.eql(u8, event_type, "summary")) return "Summary";
    if (std.mem.eql(u8, event_type, "outline")) return "Outline";
    if (std.mem.eql(u8, event_type, "wiki_revision")) return "Wiki revision";
    if (std.mem.eql(u8, event_type, "source_change")) return "Source change";
    if (std.mem.eql(u8, event_type, "paper_evidence")) return "Paper evidence";
    if (std.mem.eql(u8, event_type, "flashcard_evidence")) return "Flashcard review";
    if (std.mem.eql(u8, event_type, "processing_failure")) return "Processing failure";
    return event_type;
}

fn renderRevisions(req: mer.Request, w: *std.Io.Writer, page_id: []const u8) !void {
    const result = lib.backend.revisions(req.allocator, lib.session.fromRequest(req).token, page_id);
    if (result.value == null) {
        try w.writeAll("<section class=\"cp-boundary\" role=\"alert\"><h2>Revisions unavailable</h2><p>The revision record could not be loaded without changing the current page.</p></section>");
        return;
    }
    const revisions = result.value.?.value;
    try w.writeAll("<section class=\"cp-document-ledger cp-activity-revisions\"><header><p class=\"eyebrow\">Expanded revision</p><h2>Page revisions</h2></header>");
    for (revisions) |revision| try w.print("<article><div><h3>Revision {d} · {s}</h3><p>{s}</p></div><span class=\"cp-state status-pill\">{d} citations</span><strong>{s}</strong></article>", .{ revision.revision_number, lib.ui.escapeSafe(req.allocator, revision.title), lib.ui.escapeSafe(req.allocator, revision.change_summary), revision.citation_count, lib.ui.escapeSafe(req.allocator, revision.created_at) });
    if (revisions.len == 0) try w.writeAll("<div class=\"cp-empty\"><div><h3>No archived revisions</h3><p>This page only has its current version.</p></div></div>");
    if (revisions.len >= 2) {
        const from = revisions[1].revision_number;
        const to = revisions[0].revision_number;
        const diff = lib.backend.revisionDiff(req.allocator, lib.session.fromRequest(req).token, page_id, from, to);
        if (diff.value) |parsed| {
            const bounded = parsed.value.diff[0..@min(parsed.value.diff.len, 100 * 1024)];
            try w.print("<details class=\"cp-activity-diff\"><summary>Revision {d} to {d} · bounded to 100 KiB</summary><pre>{s}</pre></details>", .{ from, to, lib.ui.escapeSafe(req.allocator, bounded) });
        } else try w.writeAll("<p class=\"cp-settings-readonly\" role=\"alert\">The bounded diff is temporarily unavailable.</p>");
    }
    try w.writeAll("</section>");
}

fn tryFilter(req: mer.Request, w: *std.Io.Writer, label: []const u8, value: []const u8, selected: []const u8, demo: bool) !void {
    const path = if (std.mem.eql(u8, value, "all")) "/wiki/activity" else try std.fmt.allocPrint(req.allocator, "/wiki/activity?type={s}", .{value});
    const href = try lib.m3.demoHrefFor(req.allocator, demo, path);
    try w.print("<a class=\"filter-button{s}\" href=\"{s}\"{s}>{s}</a>", .{ if (std.mem.eql(u8, value, selected)) " active" else "", href, if (std.mem.eql(u8, value, selected)) " aria-current=\"page\"" else "", label });
}
