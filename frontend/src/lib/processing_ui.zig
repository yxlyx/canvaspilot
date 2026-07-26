const std = @import("std");
const types = @import("types.zig");
const ui = @import("ui.zig");

fn stageLabel(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "parse_index")) return "Parse and index";
    if (std.mem.eql(u8, name, "topic_proposals")) return "Deterministic topic mapping";
    if (std.mem.eql(u8, name, "coverage")) return "Coverage snapshot";
    if (std.mem.eql(u8, name, "wiki")) return "Wiki compilation";
    if (std.mem.eql(u8, name, "flashcards")) return "Flashcard draft generation";
    return name;
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

fn safeSlug(value: []const u8) bool {
    if (value.len == 0 or value.len > 160) return false;
    for (value) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn outcomeString(stage: types.ProcessingStageResponse, key: []const u8) ?[]const u8 {
    if (stage.outcome != .object) return null;
    const value = stage.outcome.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn outcomeFirstString(stage: types.ProcessingStageResponse, key: []const u8) ?[]const u8 {
    if (stage.outcome != .object) return null;
    const value = stage.outcome.object.get(key) orelse return null;
    if (value != .array or value.array.items.len == 0) return null;
    const first = value.array.items[0];
    return if (first == .string) first.string else null;
}

fn publicError(message: ?[]const u8) []const u8 {
    const value = message orelse return "No public error was reported.";
    if (std.mem.indexOf(u8, value, "OPENAI_API_KEY") != null or std.mem.indexOf(u8, value, "workload_identity") != null or std.mem.indexOf(u8, value, "Missing credentials") != null) return "A generation provider is not available. Connect one in Provider settings, then retry.";
    return value;
}

pub fn render(allocator: std.mem.Allocator, w: *std.Io.Writer, runs: []const types.ProcessingRunResponse, selected_id: []const u8, demo: bool) !void {
    try w.writeAll("<section class=\"cp-processing-panel surface\" id=\"processing\" aria-labelledby=\"processing-title\"");
    if (!demo) try w.writeAll(" data-processing-panel");
    try w.writeAll("><header><div><p class=\"eyebrow\">Durable processing</p><h2 id=\"processing-title\">Current and recent runs</h2><p>Indexing, optional Wiki compilation, and draft creation report their persisted state independently.</p></div></header>");
    if (demo) {
        try w.writeAll("<p class=\"cp-settings-readonly\">Synthetic fixture timeline. Retry and cancel are disabled.</p><article class=\"cp-processing-run\"><header><strong>Synthetic source run</strong><span class=\"status-pill status-info\">running</span></header><ol class=\"cp-stage-list\"><li data-status=\"succeeded\"><strong>Parse and index</strong><span>Status: succeeded</span></li><li data-status=\"running\"><strong>Wiki compilation</strong><span>Status: running</span></li><li data-status=\"blocked\"><strong>Flashcard draft generation</strong><span>Status: blocked</span></li></ol></article></section>");
        return;
    }
    try w.writeAll("<p class=\"cp-processing-poll-error\" role=\"alert\" tabindex=\"-1\" hidden data-processing-error></p><div data-processing-runs>");
    if (runs.len == 0) try w.writeAll("<p class=\"cp-empty-copy\">No processing runs yet. Bookmark links are saved as metadata; uploaded or pasted content creates a run.</p>");
    for (runs) |run| {
        const selected = selected_id.len == 0 or std.mem.eql(u8, selected_id, run.id);
        const active = std.mem.eql(u8, run.status, "queued") or std.mem.eql(u8, run.status, "running");
        try w.print("<article class=\"cp-processing-run{s}\" data-processing-run=\"{s}\" data-run-status=\"{s}\"><header><div><strong>Source version <code>{s}</code></strong><span>Created <time datetime=\"{s}\">{s}</time> · run attempt {d}</span></div><span class=\"status-pill status-{s}\">{s}</span></header>", .{ if (selected) " is-current" else "", ui.escapeSafe(allocator, run.id), ui.escapeSafe(allocator, run.status), ui.escapeSafe(allocator, run.source_version_id), ui.escapeSafe(allocator, run.created_at), ui.escapeSafe(allocator, run.created_at), run.attempt_count + 1, if (std.mem.eql(u8, run.status, "ready")) "good" else if (std.mem.eql(u8, run.status, "failed") or std.mem.eql(u8, run.status, "cancelled")) "warn" else "info", if (std.mem.eql(u8, run.status, "ready")) "completed" else ui.escapeSafe(allocator, run.status) });
        try w.writeAll("<ol class=\"cp-stage-list\">");
        for (run.stages) |stage| {
            const timestamp = stage.completed_at orelse stage.started_at orelse stage.available_at;
            try w.print("<li data-stage=\"{s}\" data-status=\"{s}\"><strong>{s}</strong><span>Status / current outcome: {s}</span><span><time datetime=\"{s}\">{s}</time> · attempt {d} of {d}</span>", .{ ui.escapeSafe(allocator, stage.name), ui.escapeSafe(allocator, stage.status), stageLabel(stage.name), ui.escapeSafe(allocator, stage.status), ui.escapeSafe(allocator, timestamp), ui.escapeSafe(allocator, timestamp), stage.attempt_count, stage.max_attempts });
            if (stage.@"error" != null) try w.print("<p role=\"alert\">{s}</p>", .{ui.escapeSafe(allocator, publicError(stage.@"error"))});
            try w.writeAll("</li>");
        }
        try w.writeAll("</ol>");
        if (run.pause_reason) |reason| try w.print("<p class=\"cp-run-guidance\"><strong>Paused:</strong> {s} {s} <a href=\"{s}\">Open settings</a>.</p>", .{ ui.escapeSafe(allocator, reason), if (std.mem.eql(u8, reason, "source_processing_disabled")) "Enable source processing before retrying." else "Connect a generation provider if this stage needs one, then retry.", if (std.mem.eql(u8, reason, "source_processing_disabled")) "/settings/learning" else "/settings/providers" });
        if (run.@"error" != null) try w.print("<p class=\"cp-run-guidance\" role=\"alert\">{s}</p>", .{ui.escapeSafe(allocator, publicError(run.@"error"))});
        try w.writeAll("<div class=\"cp-action-row\">");
        if (std.mem.eql(u8, run.status, "failed") or std.mem.eql(u8, run.status, "paused") or std.mem.eql(u8, run.status, "cancelled")) try w.print("<button class=\"cp-btn cp-btn-primary\" type=\"button\" data-processing-action=\"run.retry\" data-run-id=\"{s}\">Retry failed stage</button>", .{ui.escapeSafe(allocator, run.id)});
        if (active) try w.print("<button class=\"cp-btn cp-btn-ghost\" type=\"button\" data-processing-action=\"run.cancel\" data-run-id=\"{s}\">Cancel run</button>", .{ui.escapeSafe(allocator, run.id)});
        for (run.stages) |stage| {
            if (!std.mem.eql(u8, stage.status, "succeeded")) continue;
            if (std.mem.eql(u8, stage.name, "topic_proposals")) {
                if (outcomeString(stage, "enrollment_id")) |id| if (safeUuid(id)) try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"/learning/{s}\">Review topic mapping</a>", .{ui.escapeSafe(allocator, id)});
            } else if (std.mem.eql(u8, stage.name, "wiki")) {
                if (outcomeFirstString(stage, "page_slugs")) |slug| {
                    if (safeSlug(slug)) {
                        const enrollment_id = outcomeString(stage, "enrollment_id");
                        if (enrollment_id != null and safeUuid(enrollment_id.?)) try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"/wiki/{s}?enrollment={s}\">Open updated wiki</a>", .{ ui.escapeSafe(allocator, slug), ui.escapeSafe(allocator, enrollment_id.?) }) else try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"/wiki/{s}\">Open updated wiki</a>", .{ui.escapeSafe(allocator, slug)});
                    }
                } else if (outcomeFirstString(stage, "page_ids")) |id| {
                    if (safeUuid(id)) try w.writeAll("<a class=\"cp-btn cp-btn-ghost\" href=\"/wiki\">Open updated wiki</a>");
                }
            } else if (std.mem.eql(u8, stage.name, "flashcards")) {
                if (outcomeString(stage, "deck_id")) |id| if (safeUuid(id)) {
                    const enrollment_id = outcomeString(stage, "enrollment_id");
                    if (enrollment_id != null and safeUuid(enrollment_id.?)) try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"/flashcards?draft={s}&amp;enrollment={s}#draft-review\">Review flashcard draft</a>", .{ ui.escapeSafe(allocator, id), ui.escapeSafe(allocator, enrollment_id.?) }) else try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"/flashcards?draft={s}#draft-review\">Review flashcard draft</a>", .{ui.escapeSafe(allocator, id)});
                };
            }
        }
        try w.writeAll("</div></article>");
    }
    try w.writeAll("</div></section>");
}

test "succeeded stage actions use only validated outcome identifiers" {
    const allocator = std.testing.allocator;
    const topic = try std.json.parseFromSlice(std.json.Value, allocator, "{\"enrollment_id\":\"123e4567-e89b-12d3-a456-426614174000\"}", .{});
    defer topic.deinit();
    const wiki = try std.json.parseFromSlice(std.json.Value, allocator, "{\"enrollment_id\":\"123e4567-e89b-12d3-a456-426614174000\",\"page_slugs\":[\"safe-page\"]}", .{});
    defer wiki.deinit();
    const cards = try std.json.parseFromSlice(std.json.Value, allocator, "{\"deck_id\":\"223e4567-e89b-12d3-a456-426614174000\",\"enrollment_id\":\"123e4567-e89b-12d3-a456-426614174000\"}", .{});
    defer cards.deinit();
    const stages = [_]types.ProcessingStageResponse{
        .{ .id = "1", .name = "topic_proposals", .position = 1, .status = "succeeded", .attempt_count = 1, .max_attempts = 3, .available_at = "now", .outcome = topic.value },
        .{ .id = "2", .name = "wiki", .position = 3, .status = "succeeded", .attempt_count = 1, .max_attempts = 3, .available_at = "now", .outcome = wiki.value },
        .{ .id = "3", .name = "flashcards", .position = 4, .status = "succeeded", .attempt_count = 1, .max_attempts = 3, .available_at = "now", .outcome = cards.value },
    };
    const run: types.ProcessingRunResponse = .{ .id = "323e4567-e89b-12d3-a456-426614174000", .source_id = "423e4567-e89b-12d3-a456-426614174000", .source_version_id = "523e4567-e89b-12d3-a456-426614174000", .status = "ready", .current_stage = "flashcards", .attempt_count = 0, .created_at = "now", .updated_at = "now", .stages = &stages };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try render(allocator, &out.writer, &.{run}, "", false);
    const html = out.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/learning/123e4567-e89b-12d3-a456-426614174000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/wiki/safe-page?enrollment=123e4567-e89b-12d3-a456-426614174000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/flashcards?draft=223e4567-e89b-12d3-a456-426614174000&amp;enrollment=123e4567-e89b-12d3-a456-426614174000#draft-review\"") != null);
}
