const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const Envelope = struct {
    action: []const u8,
    enrollment_id: ?[]const u8 = null,
    preview_id: ?[]const u8 = null,
    revision_id: ?[]const u8 = null,
    association_id: ?[]const u8 = null,
    source_id: ?[]const u8 = null,
    topic_id: ?[]const u8 = null,
    payload: ?std.json.Value = null,
};

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const PreviewPayload = struct {
    academic_year: []const u8,
    share_url: ?[]const u8 = null,
    module_codes: []const []const u8 = &.{},
    semester: ?u8 = null,
};

fn validCode(code: []const u8) bool {
    if (code.len < 2 or code.len > 16) return false;
    for (code) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

fn validAcademicYear(value: []const u8) bool {
    if (value.len != 9 or value[4] != '-') return false;
    const start = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const end = std.fmt.parseInt(u16, value[5..9], 10) catch return false;
    return start >= 2000 and start <= 2100 and end == start + 1;
}

fn validPreviewBody(allocator: std.mem.Allocator, body: []const u8) bool {
    var parsed = std.json.parseFromSlice(PreviewPayload, allocator, body, .{ .ignore_unknown_fields = false }) catch return false;
    defer parsed.deinit();
    const payload = parsed.value;
    if (!validAcademicYear(payload.academic_year) or payload.module_codes.len > 30) return false;
    const has_url = if (payload.share_url) |url| url.len > 0 and url.len <= 8192 else false;
    const has_codes = payload.module_codes.len > 0;
    if (has_url == has_codes or (has_codes and (payload.semester == null or payload.semester.? < 1 or payload.semester.? > 4))) return false;
    for (payload.module_codes) |code| if (!validCode(code)) return false;
    return true;
}

fn payloadJson(allocator: std.mem.Allocator, payload: ?std.json.Value) ![]const u8 {
    const value = payload orelse return "{}";
    var out: std.Io.Writer.Allocating = .init(allocator);
    var writer: std.json.Stringify = .{ .writer = &out.writer };
    try writer.write(value);
    return out.written();
}

const CommitPayload = struct {
    selected_codes: []const []const u8 = &.{},
    archive_codes: []const []const u8 = &.{},
};
const ProposalPayload = struct { source_ids: []const []const u8 = &.{} };
const ManualPayload = struct {
    topic_id: []const u8,
    source_id: []const u8,
    chunk_ids: []const []const u8,
    reason_code: []const u8 = "manual_source_review",
};
const DecisionPayload = struct { decision: []const u8 };

fn validCoverageBody(allocator: std.mem.Allocator, action: []const u8, body: []const u8) bool {
    if (std.mem.eql(u8, action, "import.commit")) {
        var parsed = std.json.parseFromSlice(CommitPayload, allocator, body, .{ .ignore_unknown_fields = false }) catch return false;
        defer parsed.deinit();
        const selected = parsed.value.selected_codes;
        const archived = parsed.value.archive_codes;
        if (selected.len + archived.len < 1 or selected.len + archived.len > 30) return false;
        for (selected, 0..) |code, index| {
            if (!validCode(code)) return false;
            for (selected[0..index]) |prior| if (std.ascii.eqlIgnoreCase(code, prior)) return false;
            for (archived) |other| if (std.ascii.eqlIgnoreCase(code, other)) return false;
        }
        for (archived, 0..) |code, index| {
            if (!validCode(code)) return false;
            for (archived[0..index]) |prior| if (std.ascii.eqlIgnoreCase(code, prior)) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, action, "coverage.recompute")) {
        var parsed = std.json.parseFromSlice(ProposalPayload, allocator, body, .{ .ignore_unknown_fields = false }) catch return false;
        defer parsed.deinit();
        if (parsed.value.source_ids.len > 100) return false;
        for (parsed.value.source_ids, 0..) |id, index| {
            if (!safeUuid(id)) return false;
            for (parsed.value.source_ids[0..index]) |prior| if (std.mem.eql(u8, id, prior)) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, action, "association.manual")) {
        var parsed = std.json.parseFromSlice(ManualPayload, allocator, body, .{ .ignore_unknown_fields = false }) catch return false;
        defer parsed.deinit();
        if (!safeUuid(parsed.value.topic_id) or !safeUuid(parsed.value.source_id) or parsed.value.chunk_ids.len < 1 or parsed.value.chunk_ids.len > 20 or parsed.value.reason_code.len < 1 or parsed.value.reason_code.len > 64) return false;
        for (parsed.value.chunk_ids, 0..) |id, index| {
            if (!safeUuid(id)) return false;
            for (parsed.value.chunk_ids[0..index]) |prior| if (std.mem.eql(u8, id, prior)) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, action, "association.decide")) {
        var parsed = std.json.parseFromSlice(DecisionPayload, allocator, body, .{ .ignore_unknown_fields = false }) catch return false;
        defer parsed.deinit();
        return std.mem.eql(u8, parsed.value.decision, "confirm") or std.mem.eql(u8, parsed.value.decision, "reject");
    }
    return true;
}

fn route(allocator: std.mem.Allocator, envelope: Envelope) !struct { std.http.Method, []const u8 } {
    if (std.mem.eql(u8, envelope.action, "import.preview")) return .{ .POST, "/api/nusmods/imports/preview" };
    if (std.mem.eql(u8, envelope.action, "enrollments.list")) return .{ .GET, "/api/enrollments" };
    if (std.mem.eql(u8, envelope.action, "import.commit")) {
        const id = envelope.preview_id orelse return error.InvalidRoute;
        if (!safeUuid(id)) return error.InvalidRoute;
        return .{ .POST, try std.fmt.allocPrint(allocator, "/api/nusmods/imports/{s}/commit", .{id}) };
    }
    const enrollment_id = envelope.enrollment_id orelse return error.InvalidRoute;
    if (!safeUuid(enrollment_id)) return error.InvalidRoute;
    if (std.mem.eql(u8, envelope.action, "topics.list")) return .{ .GET, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/topics", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "topics.save")) return .{ .PUT, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/topics", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "coverage.get")) return .{ .GET, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/coverage", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "metrics.get")) return .{ .GET, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/learning-metrics", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "coverage.recompute")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/coverage/proposals", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "candidates.list")) return .{ .GET, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/candidate-sources", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "chunks.list")) {
        const source_id = envelope.source_id orelse return error.InvalidRoute;
        const topic_id = envelope.topic_id orelse return error.InvalidRoute;
        if (!safeUuid(source_id) or !safeUuid(topic_id)) return error.InvalidRoute;
        return .{ .GET, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/candidate-sources/{s}/chunks?topic_id={s}", .{ enrollment_id, source_id, topic_id }) };
    }
    if (std.mem.eql(u8, envelope.action, "association.manual")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/source-associations", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "association.decide") or std.mem.eql(u8, envelope.action, "association.remove")) {
        const association_id = envelope.association_id orelse return error.InvalidRoute;
        if (!safeUuid(association_id)) return error.InvalidRoute;
        if (std.mem.eql(u8, envelope.action, "association.remove")) return .{ .DELETE, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/source-associations/{s}", .{ enrollment_id, association_id }) };
        return .{ .POST, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/source-associations/{s}/decision", .{ enrollment_id, association_id }) };
    }
    if (std.mem.eql(u8, envelope.action, "revision.preview")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/topic-revisions", .{enrollment_id}) };
    if (std.mem.eql(u8, envelope.action, "revision.decide")) {
        const revision_id = envelope.revision_id orelse return error.InvalidRoute;
        if (!safeUuid(revision_id)) return error.InvalidRoute;
        return .{ .POST, try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/topic-revisions/{s}", .{ enrollment_id, revision_id }) };
    }
    return error.InvalidRoute;
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    if (lib.m3.isExplicitDemo(req)) return mer.badRequest("mutations and live requests are unavailable in synthetic preview mode");
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    if (lib.mutation.guard(req, 128 * 1024)) |response| return response;
    const parsed = std.json.parseFromSlice(Envelope, req.allocator, req.body, .{ .ignore_unknown_fields = false }) catch return mer.badRequest("invalid curriculum request");
    const target = route(req.allocator, parsed.value) catch return mer.badRequest("invalid curriculum action or identifier");
    const body = if (target[0].requestHasBody()) payloadJson(req.allocator, parsed.value.payload) catch return mer.badRequest("invalid curriculum payload") else null;
    if (std.mem.eql(u8, parsed.value.action, "import.preview") and !validPreviewBody(req.allocator, body.?)) return mer.badRequest("invalid import preview fields");
    if (target[0].requestHasBody() and !validCoverageBody(req.allocator, parsed.value.action, body.?)) return mer.badRequest("invalid curriculum payload");
    const result = lib.backend.proxy(req.allocator, session.token, "", target[0], target[1], body, 2 * 1024 * 1024);
    if (result.status == 0) return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"curriculum service unavailable\"}" };
    if (result.status == 401) {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("session clear failed");
        cookies[0] = lib.session.clearCookie();
        return mer.withCookies(.{ .status = .unauthorized, .content_type = .json, .body = result.body }, cookies);
    }
    return .{ .status = @enumFromInt(result.status), .content_type = .json, .body = result.body };
}

test "import preview validation mirrors bounded backend fields" {
    try std.testing.expect(validPreviewBody(std.testing.allocator, "{\"academic_year\":\"2025-2026\",\"share_url\":\"https://nusmods.com/timetable/sem-1/share\",\"semester\":1}"));
    try std.testing.expect(validPreviewBody(std.testing.allocator, "{\"academic_year\":\"2025-2026\",\"module_codes\":[\"CS2040S\"],\"semester\":1}"));
    try std.testing.expect(!validPreviewBody(std.testing.allocator, "{\"academic_year\":\"2025-2027\",\"module_codes\":[\"CS 2040\"],\"semester\":1}"));
    try std.testing.expect(!validPreviewBody(std.testing.allocator, "{\"academic_year\":\"2025-2026\",\"share_url\":\"https://nusmods.com\",\"module_codes\":[\"CS2040S\"],\"semester\":1}"));
}

test "import commit requires bounded unique disjoint decisions" {
    const allocator = std.testing.allocator;
    try std.testing.expect(validCoverageBody(allocator, "import.commit", "{\"selected_codes\":[\"CS2040S\"],\"archive_codes\":[\"CS1010S\"]}"));
    try std.testing.expect(!validCoverageBody(allocator, "import.commit", "{\"selected_codes\":[],\"archive_codes\":[]}"));
    try std.testing.expect(!validCoverageBody(allocator, "import.commit", "{\"selected_codes\":[\"CS2040S\"],\"archive_codes\":[\"cs2040s\"]}"));
    try std.testing.expect(!validCoverageBody(allocator, "import.commit", "{\"selected_codes\":[\"CS 2040\"],\"archive_codes\":[]}"));
}

test "curriculum bridge only accepts UUID-bound routes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(safeUuid("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expect(!safeUuid("../enrollments"));
    try std.testing.expectError(error.InvalidRoute, route(allocator, .{ .action = "topics.save", .enrollment_id = "not-a-uuid" }));
    const target = try route(allocator, .{ .action = "import.commit", .preview_id = "123e4567-e89b-12d3-a456-426614174000" });
    try std.testing.expectEqual(std.http.Method.POST, target[0]);
    try std.testing.expectEqualStrings("/api/nusmods/imports/123e4567-e89b-12d3-a456-426614174000/commit", target[1]);
    const coverage = try route(allocator, .{ .action = "coverage.get", .enrollment_id = "123e4567-e89b-12d3-a456-426614174000" });
    try std.testing.expectEqualStrings("/api/enrollments/123e4567-e89b-12d3-a456-426614174000/coverage", coverage[1]);
    const metrics = try route(allocator, .{ .action = "metrics.get", .enrollment_id = "123e4567-e89b-12d3-a456-426614174000" });
    try std.testing.expectEqual(std.http.Method.GET, metrics[0]);
    try std.testing.expectEqualStrings("/api/enrollments/123e4567-e89b-12d3-a456-426614174000/learning-metrics", metrics[1]);
    const chunks = try route(allocator, .{ .action = "chunks.list", .enrollment_id = "123e4567-e89b-12d3-a456-426614174000", .source_id = "223e4567-e89b-12d3-a456-426614174000", .topic_id = "323e4567-e89b-12d3-a456-426614174000" });
    try std.testing.expectEqualStrings("/api/enrollments/123e4567-e89b-12d3-a456-426614174000/candidate-sources/223e4567-e89b-12d3-a456-426614174000/chunks?topic_id=323e4567-e89b-12d3-a456-426614174000", chunks[1]);
    try std.testing.expectError(error.InvalidRoute, route(allocator, .{ .action = "chunks.list", .enrollment_id = "123e4567-e89b-12d3-a456-426614174000", .source_id = "../bad", .topic_id = "323e4567-e89b-12d3-a456-426614174000" }));
    try std.testing.expectError(error.InvalidRoute, route(allocator, .{ .action = "association.remove", .enrollment_id = "123e4567-e89b-12d3-a456-426614174000", .association_id = "../bad" }));
}

test "coverage bridge enforces backend request bounds" {
    try std.testing.expect(validCoverageBody(std.testing.allocator, "coverage.recompute", "{\"source_ids\":[\"123e4567-e89b-12d3-a456-426614174000\"]}"));
    try std.testing.expect(!validCoverageBody(std.testing.allocator, "coverage.recompute", "{\"source_ids\":[\"bad\"]}"));
    try std.testing.expect(validCoverageBody(std.testing.allocator, "association.manual", "{\"topic_id\":\"123e4567-e89b-12d3-a456-426614174000\",\"source_id\":\"223e4567-e89b-12d3-a456-426614174000\",\"chunk_ids\":[\"323e4567-e89b-12d3-a456-426614174000\"]}"));
    try std.testing.expect(!validCoverageBody(std.testing.allocator, "association.manual", "{\"topic_id\":\"123e4567-e89b-12d3-a456-426614174000\",\"source_id\":\"223e4567-e89b-12d3-a456-426614174000\",\"chunk_ids\":[]}"));
    try std.testing.expect(!validCoverageBody(std.testing.allocator, "association.decide", "{\"decision\":\"approve\"}"));
}
