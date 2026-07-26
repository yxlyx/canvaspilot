const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const max_body = 32 * 1024;
const Envelope = struct {
    action: []const u8,
    id: ?[]const u8 = null,
    source_id: ?[]const u8 = null,
    limit: ?u8 = null,
    idempotency_key: []const u8 = "",
    payload: ?std.json.Value = null,
};

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

fn safeKey(value: []const u8) bool {
    if (value.len < 16 or value.len > 128) return false;
    for (value) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn allowedStage(value: []const u8) bool {
    return std.mem.eql(u8, value, "parse_index") or std.mem.eql(u8, value, "topic_proposals") or std.mem.eql(u8, value, "coverage") or std.mem.eql(u8, value, "wiki") or std.mem.eql(u8, value, "flashcards");
}

fn validPayload(envelope: Envelope) bool {
    const value = envelope.payload orelse return !std.mem.eql(u8, envelope.action, "policy.update") and !std.mem.eql(u8, envelope.action, "manual.trigger");
    if (value != .object) return false;
    const object = value.object;
    if (std.mem.eql(u8, envelope.action, "manual.trigger")) {
        const source = object.get("source_id") orelse return false;
        if (source != .string or !safeUuid(source.string)) return false;
        var iterator = object.iterator();
        while (iterator.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, "source_id")) return false;
        return true;
    }
    if (std.mem.eql(u8, envelope.action, "run.retry")) {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "from_stage") or entry.value_ptr.* != .string or !allowedStage(entry.value_ptr.string)) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, envelope.action, "policy.update")) {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            const item = entry.value_ptr.*;
            if (std.mem.eql(u8, name, "process_sources") or std.mem.eql(u8, name, "map_topics") or std.mem.eql(u8, name, "compile_wiki")) {
                if (item != .bool) return false;
            } else if (std.mem.eql(u8, name, "flashcard_mode")) {
                if (item != .string or (!std.mem.eql(u8, item.string, "off") and !std.mem.eql(u8, item.string, "suggest") and !std.mem.eql(u8, item.string, "draft"))) return false;
            } else return false;
        }
        return true;
    }
    return object.count() == 0;
}

fn payloadJson(allocator: std.mem.Allocator, payload: ?std.json.Value) !?[]const u8 {
    const value = payload orelse return null;
    if (value != .object) return error.InvalidPayload;
    var out: std.Io.Writer.Allocating = .init(allocator);
    var writer: std.json.Stringify = .{ .writer = &out.writer };
    try writer.write(value);
    return out.written();
}

fn route(allocator: std.mem.Allocator, envelope: Envelope) !struct { std.http.Method, []const u8, bool } {
    if (std.mem.eql(u8, envelope.action, "run.list")) {
        const limit = envelope.limit orelse 20;
        if (limit == 0 or limit > 100) return error.InvalidRoute;
        if (envelope.source_id) |source_id| {
            if (!safeUuid(source_id)) return error.InvalidRoute;
            return .{ .GET, try std.fmt.allocPrint(allocator, "/api/processing/runs?source_id={s}&limit={d}", .{ source_id, limit }), false };
        }
        return .{ .GET, try std.fmt.allocPrint(allocator, "/api/processing/runs?limit={d}", .{limit}), false };
    }
    if (std.mem.eql(u8, envelope.action, "policy.get")) return .{ .GET, "/api/processing/policy", false };
    if (std.mem.eql(u8, envelope.action, "policy.update")) return .{ .PATCH, "/api/processing/policy", true };
    if (std.mem.eql(u8, envelope.action, "manual.trigger")) return .{ .POST, "/api/processing/trigger", true };

    const id = envelope.id orelse return error.InvalidRoute;
    if (!safeUuid(id)) return error.InvalidRoute;
    if (std.mem.eql(u8, envelope.action, "run.status")) return .{ .GET, try std.fmt.allocPrint(allocator, "/api/processing/runs/{s}", .{id}), false };
    if (std.mem.eql(u8, envelope.action, "run.retry")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/processing/runs/{s}/retry", .{id}), true };
    if (std.mem.eql(u8, envelope.action, "run.cancel")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/processing/runs/{s}/cancel", .{id}), true };
    return error.InvalidRoute;
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    if (lib.m3.isExplicitDemo(req)) return mer.badRequest("processing mutations are unavailable in demo mode");
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    if (lib.mutation.guard(req, max_body)) |response| return response;
    const parsed = std.json.parseFromSlice(Envelope, req.allocator, req.body, .{ .ignore_unknown_fields = false }) catch return mer.badRequest("invalid processing request");
    const target = route(req.allocator, parsed.value) catch return mer.badRequest("invalid processing action");
    if (!validPayload(parsed.value)) return mer.badRequest("invalid processing payload");
    if (target[2] and !safeKey(parsed.value.idempotency_key)) return mer.badRequest("invalid idempotency key");
    const body = payloadJson(req.allocator, parsed.value.payload) catch return mer.badRequest("invalid processing payload");
    if (!target[0].requestHasBody() and body != null) return mer.badRequest("payload is not allowed for this action");
    const result = lib.backend.proxy(req.allocator, session.token, parsed.value.idempotency_key, target[0], target[1], body, 2 * 1024 * 1024);
    if (result.status == 0) return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"processing service unavailable\"}" };
    return .{ .status = @enumFromInt(result.status), .content_type = .json, .body = result.body };
}

test "processing bridge validates identifiers and allowlisted actions" {
    const allocator = std.testing.allocator;
    const id = "123e4567-e89b-12d3-a456-426614174000";
    const status = try route(allocator, .{ .action = "run.status", .id = id });
    defer allocator.free(status[1]);
    try std.testing.expectEqualStrings("/api/processing/runs/123e4567-e89b-12d3-a456-426614174000", status[1]);
    try std.testing.expectError(error.InvalidRoute, route(allocator, .{ .action = "run.cancel", .id = "../private" }));
    try std.testing.expectError(error.InvalidRoute, route(allocator, .{ .action = "fetch", .id = id }));
    try std.testing.expect(safeKey("submit-1234567890"));
    try std.testing.expect(!safeKey("short"));
}
