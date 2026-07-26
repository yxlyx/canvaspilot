const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const max_import_body = 15 * 1024 * 1024;

fn safeKey(value: []const u8) bool {
    if (value.len < 16 or value.len > 128) return false;
    for (value) |char| switch (char) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) {
        return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    }
    if (lib.m3.isExplicitDemo(req)) return mer.badRequest("source imports are unavailable in demo mode");
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) {
        return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    }
    if (lib.mutation.guard(req, max_import_body)) |response| return response;
    const idempotency_key = req.header("idempotency-key") orelse return mer.badRequest("missing Idempotency-Key header");
    if (!safeKey(idempotency_key)) return mer.badRequest("invalid Idempotency-Key header");

    const result = lib.backend.proxy(
        req.allocator,
        session.token,
        idempotency_key,
        .POST,
        "/api/sources/import",
        req.body,
        2 * 1024 * 1024,
    );
    if (result.status == 0) {
        return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"source import unavailable\"}" };
    }
    return .{
        .status = @enumFromInt(result.status),
        .content_type = .json,
        .body = result.body,
    };
}

test "source intake requires bounded idempotency keys" {
    try std.testing.expect(safeKey("source-1234567890"));
    try std.testing.expect(!safeKey("short"));
    try std.testing.expect(!safeKey("source key with spaces"));
}
