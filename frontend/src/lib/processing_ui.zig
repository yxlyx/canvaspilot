const std = @import("std");
const types = @import("types.zig");
const time = @import("time.zig");
const ui = @import("ui.zig");

pub fn stageLabel(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "parse_index")) return "Reading document";
    if (std.mem.eql(u8, name, "topic_proposals")) return "Organising topics";
    if (std.mem.eql(u8, name, "coverage")) return "Updating coverage";
    if (std.mem.eql(u8, name, "wiki")) return "Refreshing Wiki";
    if (std.mem.eql(u8, name, "flashcards")) return "Preparing flashcards";
    if (std.mem.eql(u8, name, "ready")) return "Source ready";
    return name;
}

fn completedStageLabel(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "parse_index")) return "Document read";
    if (std.mem.eql(u8, name, "topic_proposals")) return "Topics organised";
    if (std.mem.eql(u8, name, "coverage")) return "Coverage updated";
    if (std.mem.eql(u8, name, "wiki")) return "Wiki refreshed";
    if (std.mem.eql(u8, name, "flashcards")) return "Flashcards prepared";
    return stageLabel(name);
}

fn stageState(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "succeeded")) return "Done";
    if (std.mem.eql(u8, status, "skipped")) return "Not needed";
    if (std.mem.eql(u8, status, "running")) return "In progress";
    if (std.mem.eql(u8, status, "queued")) return "Waiting";
    if (std.mem.eql(u8, status, "blocked")) return "Next";
    if (std.mem.eql(u8, status, "failed")) return "Needs attention";
    if (std.mem.eql(u8, status, "paused")) return "Paused";
    if (std.mem.eql(u8, status, "cancelled")) return "Stopped";
    return "Saved";
}

fn runState(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "ready")) return "Completed";
    if (std.mem.eql(u8, status, "queued")) return "Waiting";
    if (std.mem.eql(u8, status, "running")) return "In progress";
    if (std.mem.eql(u8, status, "failed")) return "Needs attention";
    if (std.mem.eql(u8, status, "paused")) return "Paused";
    if (std.mem.eql(u8, status, "cancelled")) return "Stopped";
    return status;
}

fn sourceTitle(sources: []const types.SourceResponse, source_id: []const u8) []const u8 {
    for (sources) |source| if (std.mem.eql(u8, source.id, source_id)) return source.title;
    return "Imported source";
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

pub fn render(allocator: std.mem.Allocator, w: *std.Io.Writer, runs: []const types.ProcessingRunResponse, sources: []const types.SourceResponse, selected_id: []const u8, demo: bool) !void {
    try w.writeAll("<section class=\"cp-processing-panel surface\" id=\"processing\" aria-labelledby=\"processing-title\"");
    if (!demo) try w.writeAll(" data-processing-panel");
    try w.writeAll("><header><div><p class=\"eyebrow\">Source activity</p><h2 id=\"processing-title\">What happened to your sources</h2><p>A simple record of what is ready, still running, or needs your attention.</p></div></header>");
    if (demo) {
        try w.writeAll("<p class=\"cp-settings-readonly\">Illustrative activity. Actions are unavailable in the demo.</p><article class=\"cp-processing-run\" data-run-status=\"running\"><header><div class=\"cp-processing-source\"><span class=\"cp-run-indicator\" aria-hidden=\"true\"></span><div><strong>Synthetic lecture notes</strong><span>Refreshing Wiki</span></div></div><span class=\"status-pill status-info\">In progress</span></header><ol class=\"cp-stage-list\"><li data-status=\"succeeded\"><span class=\"cp-stage-indicator\" aria-hidden=\"true\"></span><div><strong>Document read</strong><span>Done</span></div></li><li data-status=\"running\"><span class=\"cp-stage-indicator\" aria-hidden=\"true\"></span><div><strong>Wiki refresh</strong><span>In progress</span></div></li><li data-status=\"blocked\"><span class=\"cp-stage-indicator\" aria-hidden=\"true\"></span><div><strong>Flashcards</strong><span>Next</span></div></li></ol></article></section>");
        return;
    }
    try w.writeAll("<p class=\"cp-processing-poll-error\" role=\"alert\" tabindex=\"-1\" hidden data-processing-error></p><div data-processing-runs>");
    if (runs.len == 0) try w.writeAll("<p class=\"cp-empty-copy\">No processing runs yet. Bookmark links are saved as metadata; uploaded or pasted content creates a run.</p>");
    for (runs) |run| {
        const selected = selected_id.len == 0 or std.mem.eql(u8, selected_id, run.id);
        const active = std.mem.eql(u8, run.status, "queued") or std.mem.eql(u8, run.status, "running");
        const updated = time.formatRelative(allocator, run.updated_at, time.nowSecs()) catch "recently";
        const current_stage = if (std.mem.eql(u8, run.status, "ready")) "All selected steps finished" else stageLabel(run.current_stage);
        try w.print("<article class=\"cp-processing-run{s}\" data-processing-run=\"{s}\" data-run-status=\"{s}\" data-run-stage=\"{s}\"><header><div class=\"cp-processing-source\"><span class=\"cp-run-indicator\" aria-hidden=\"true\"></span><div><strong>{s}</strong><span><span data-current-stage>{s}</span> · updated {s}</span></div></div><span class=\"status-pill status-{s}\">{s}</span><span class=\"sr-only\" data-run-live role=\"status\" aria-live=\"polite\" aria-atomic=\"true\"></span></header>", .{ if (selected) " is-current" else "", ui.escapeSafe(allocator, run.id), ui.escapeSafe(allocator, run.status), ui.escapeSafe(allocator, run.current_stage), ui.escapeSafe(allocator, sourceTitle(sources, run.source_id)), ui.escapeSafe(allocator, current_stage), ui.escapeSafe(allocator, updated), if (std.mem.eql(u8, run.status, "ready")) "good" else if (std.mem.eql(u8, run.status, "failed") or std.mem.eql(u8, run.status, "cancelled") or std.mem.eql(u8, run.status, "paused")) "warn" else "info", ui.escapeSafe(allocator, runState(run.status)) });
        try w.writeAll("<ol class=\"cp-stage-list\">");
        for (run.stages) |stage| {
            const label = if (std.mem.eql(u8, stage.status, "succeeded")) completedStageLabel(stage.name) else stageLabel(stage.name);
            try w.print("<li data-stage=\"{s}\" data-status=\"{s}\"><span class=\"cp-stage-indicator\" aria-hidden=\"true\"></span><div><strong>{s}</strong><span data-stage-state>{s}</span></div>", .{ ui.escapeSafe(allocator, stage.name), ui.escapeSafe(allocator, stage.status), ui.escapeSafe(allocator, label), ui.escapeSafe(allocator, stageState(stage.status)) });
            if (stage.@"error" != null) try w.print("<p role=\"alert\">{s}</p>", .{ui.escapeSafe(allocator, publicError(stage.@"error"))});
            try w.writeAll("</li>");
        }
        try w.writeAll("</ol>");
        if (std.mem.eql(u8, run.status, "queued")) {
            const updated_secs = time.parseIsoSecs(run.updated_at);
            if (updated_secs != null and time.nowSecs() - updated_secs.? >= 60) try w.writeAll("<p class=\"cp-run-guidance\" role=\"status\"><strong>This is taking longer than usual.</strong> Your document is saved. You can leave this page and check again later.</p>");
        }
        if (run.pause_reason) |reason| {
            if (std.mem.eql(u8, reason, "source_processing_disabled")) {
                try w.writeAll("<p class=\"cp-run-guidance\"><strong>Processing is paused.</strong> Turn source processing back on, then retry. <a href=\"/sources/health#processing-policy\">Open processing controls</a>.</p>");
            } else {
                try w.writeAll("<p class=\"cp-run-guidance\"><strong>A generation step is paused.</strong> Check your provider connection, then retry. <a href=\"/settings/providers\">Open provider settings</a>.</p>");
            }
        }
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
    const source: types.SourceResponse = .{ .id = run.source_id, .user_id = "user", .source_type = "pdf", .title = "Lecture 08", .status = "ready" };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try render(allocator, &out.writer, &.{run}, &.{source}, "", false);
    const html = out.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "Lecture 08") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, run.source_version_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/learning/123e4567-e89b-12d3-a456-426614174000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/wiki/safe-page?enrollment=123e4567-e89b-12d3-a456-426614174000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/flashcards?draft=223e4567-e89b-12d3-a456-426614174000&amp;enrollment=123e4567-e89b-12d3-a456-426614174000#draft-review\"") != null);
}

test "processing labels remain learner readable" {
    try std.testing.expectEqualStrings("Source ready", stageLabel("ready"));
    try std.testing.expectEqualStrings("Not needed", stageState("skipped"));
    try std.testing.expectEqualStrings("Document read", completedStageLabel("parse_index"));
}

test "queued processing explains saved state without implementation details" {
    const stage: types.ProcessingStageResponse = .{ .id = "1", .name = "parse_index", .position = 0, .status = "queued", .attempt_count = 0, .max_attempts = 3, .available_at = "2020-01-01T00:00:00Z" };
    const run: types.ProcessingRunResponse = .{ .id = "123e4567-e89b-12d3-a456-426614174000", .source_id = "223e4567-e89b-12d3-a456-426614174000", .source_version_id = "323e4567-e89b-12d3-a456-426614174000", .status = "queued", .current_stage = "parse_index", .attempt_count = 0, .created_at = "2020-01-01T00:00:00Z", .updated_at = "2020-01-01T00:00:00Z", .stages = &.{stage} };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(std.testing.allocator, &out.writer, &.{run}, &.{}, "", false);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "This is taking longer than usual.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Your document is saved") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "source version") == null);
}
