const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const Envelope = struct {
    action: []const u8,
    deck_id: ?[]const u8 = null,
    card_id: ?[]const u8 = null,
    expected_revision: ?usize = null,
    idempotency_key: []const u8,
    payload: ?std.json.Value = null,
};

fn uuid(value: ?[]const u8) bool {
    const raw = value orelse return false;
    if (raw.len != 36) return false;
    for (raw, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

fn key(value: []const u8) bool {
    if (value.len < 16 or value.len > 128) return false;
    for (value) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn payloadJson(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const payload = value orelse return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    var writer: std.json.Stringify = .{ .writer = &out.writer };
    try writer.write(payload);
    return out.written();
}

const Target = struct { method: std.http.Method, path: []const u8, revision: bool = false };

fn target(allocator: std.mem.Allocator, envelope: Envelope) !Target {
    const action = envelope.action;
    if (std.mem.eql(u8, action, "generate")) return .{ .method = .POST, .path = "/api/flashcards/decks/generate" };
    const deck = envelope.deck_id orelse return error.InvalidRoute;
    if (!uuid(deck)) return error.InvalidRoute;
    if (std.mem.eql(u8, action, "topics")) return .{ .method = .GET, .path = try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/topics", .{deck}) };
    if (std.mem.eql(u8, action, "candidates")) return .{ .method = .GET, .path = try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/candidate-sources", .{deck}) };
    if (std.mem.eql(u8, action, "chunks")) {
        const payload = envelope.payload orelse return error.InvalidRoute;
        if (payload != .object) return error.InvalidRoute;
        const source = payload.object.get("source_id") orelse return error.InvalidRoute;
        const topic = payload.object.get("topic_id") orelse return error.InvalidRoute;
        if (source != .string or topic != .string or !uuid(source.string) or !uuid(topic.string)) return error.InvalidRoute;
        return .{ .method = .GET, .path = try std.fmt.allocPrint(allocator, "/api/enrollments/{s}/candidate-sources/{s}/chunks?topic_id={s}", .{ deck, source.string, topic.string }) };
    }
    if (std.mem.eql(u8, action, "update_deck")) return .{ .method = .PATCH, .path = try std.fmt.allocPrint(allocator, "/api/flashcards/drafts/{s}", .{deck}), .revision = true };
    if (std.mem.eql(u8, action, "add_card")) return .{ .method = .POST, .path = try std.fmt.allocPrint(allocator, "/api/flashcards/drafts/{s}/cards", .{deck}), .revision = true };
    if (std.mem.eql(u8, action, "reorder") or std.mem.eql(u8, action, "discard") or std.mem.eql(u8, action, "restore") or std.mem.eql(u8, action, "approve")) return .{ .method = .POST, .path = try std.fmt.allocPrint(allocator, "/api/flashcards/drafts/{s}/{s}", .{ deck, action }), .revision = true };
    if (std.mem.eql(u8, action, "publish") or std.mem.eql(u8, action, "archive") or std.mem.eql(u8, action, "retire")) return .{ .method = .POST, .path = try std.fmt.allocPrint(allocator, "/api/flashcards/decks/{s}/{s}", .{ deck, action }), .revision = true };
    const card = envelope.card_id orelse return error.InvalidRoute;
    if (!uuid(card)) return error.InvalidRoute;
    if (std.mem.eql(u8, action, "update_card")) return .{ .method = .PATCH, .path = try std.fmt.allocPrint(allocator, "/api/flashcards/drafts/{s}/cards/{s}", .{ deck, card }), .revision = true };
    if (std.mem.eql(u8, action, "attempt")) return .{ .method = .POST, .path = try std.fmt.allocPrint(allocator, "/api/flashcards/cards/{s}/attempts", .{card}) };
    return error.InvalidRoute;
}

fn revisionPayload(allocator: std.mem.Allocator, payload: ?std.json.Value, revision: usize) ![]const u8 {
    var value = payload orelse std.json.Value{ .object = .empty };
    if (value != .object) return error.InvalidPayload;
    try value.object.put(allocator, "expected_revision", .{ .integer = @intCast(revision) });
    return (try payloadJson(allocator, value)).?;
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    if (lib.m3.isExplicitDemo(req)) return mer.badRequest("flashcard mutations are unavailable in demo mode");
    if (lib.mutation.guard(req, 128 * 1024)) |response| return response;
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return .{ .status = .unauthorized, .content_type = .json, .body = "{\"detail\":\"session expired\"}" };
    const parsed = std.json.parseFromSlice(Envelope, req.allocator, req.body, .{ .ignore_unknown_fields = false }) catch return mer.badRequest("invalid flashcard request");
    const envelope = parsed.value;
    if (!key(envelope.idempotency_key)) return mer.badRequest("invalid idempotency key");
    const destination = target(req.allocator, envelope) catch return mer.badRequest("unknown flashcard action");
    if (destination.revision and (envelope.expected_revision orelse 0) < 1) return mer.badRequest("expected revision is required");
    const body: ?[]const u8 = if (!destination.method.requestHasBody()) null else if (destination.revision)
        revisionPayload(req.allocator, envelope.payload, envelope.expected_revision.?) catch return mer.badRequest("invalid flashcard payload")
    else
        payloadJson(req.allocator, envelope.payload) catch return mer.badRequest("invalid flashcard payload");
    const result = lib.backend.proxy(req.allocator, session.token, envelope.idempotency_key, destination.method, destination.path, body, 512 * 1024);
    if (result.status == 0) return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"detail\":\"backend unavailable\"}" };
    return .{ .status = @enumFromInt(result.status), .content_type = .json, .body = result.body };
}

test "flashcard bridge accepts UUIDs and only bounded idempotency keys" {
    try std.testing.expect(uuid("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expect(!uuid("../decks"));
    try std.testing.expect(key("rating-1234567890"));
    try std.testing.expect(!key("short"));
    try std.testing.expect(!key("invalid key 123456"));
}

test "flashcard bridge allowlist binds deck and card identifiers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const route = try target(arena.allocator(), .{ .action = "update_card", .deck_id = "123e4567-e89b-12d3-a456-426614174000", .card_id = "223e4567-e89b-12d3-a456-426614174000", .idempotency_key = "request-123456789" });
    try std.testing.expectEqual(std.http.Method.PATCH, route.method);
    try std.testing.expectEqualStrings("/api/flashcards/drafts/123e4567-e89b-12d3-a456-426614174000/cards/223e4567-e89b-12d3-a456-426614174000", route.path);
    try std.testing.expectError(error.InvalidRoute, target(arena.allocator(), .{ .action = "fetch", .deck_id = "123e4567-e89b-12d3-a456-426614174000", .idempotency_key = "request-123456789" }));
}
