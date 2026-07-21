const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const Envelope = struct {
    action: []const u8,
    idempotency_key: []const u8 = "",
    id: ?[]const u8 = null,
    child_id: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    payload: ?std.json.Value = null,
};
fn safeSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn mediaType(value: ?[]const u8) []const u8 {
    const raw = value orelse return "";
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " \t");
}

fn canonicalDisposition(allocator: std.mem.Allocator, value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (raw.len > 512 or std.mem.indexOfAny(u8, raw, "\r\n") != null) return null;
    var fields = std.mem.splitScalar(u8, raw, ';');
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, fields.first(), " \t"), "attachment")) return null;
    while (fields.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " \t");
        if (trimmed.len < 9 or !std.ascii.eqlIgnoreCase(trimmed[0..9], "filename=")) continue;
        var filename = std.mem.trim(u8, trimmed[9..], " \t");
        if (filename.len >= 2 and filename[0] == '"' and filename[filename.len - 1] == '"') filename = filename[1 .. filename.len - 1];
        if (filename.len == 0 or filename.len > 255) return null;
        for (filename) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return null,
        };
        return std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{filename}) catch null;
    }
    return null;
}

fn payloadJson(allocator: std.mem.Allocator, payload: ?std.json.Value) !?[]const u8 {
    const value = payload orelse return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    var writer: std.json.Stringify = .{ .writer = &out.writer };
    try writer.write(value);
    return out.written();
}
fn route(allocator: std.mem.Allocator, envelope: Envelope) !struct { std.http.Method, []const u8, bool } {
    const action = envelope.action;
    if (std.mem.eql(u8, action, "output.create")) return .{ .POST, "/api/outputs", false };
    if (std.mem.eql(u8, action, "health.run")) return .{ .POST, "/api/workspace/health", false };
    if (std.mem.eql(u8, action, "paper.upload")) return .{ .POST, "/api/marked-papers", false };
    if (std.mem.eql(u8, action, "provider.save")) return .{ .PUT, "/api/providers/settings", false };
    if (std.mem.eql(u8, action, "wiki.export")) return .{ .POST, "/api/wiki/download", true };
    if (std.mem.eql(u8, action, "page.download")) {
        const slug = envelope.slug orelse return error.InvalidRoute;
        if (!safeSegment(slug)) return error.InvalidRoute;
        return .{ .GET, try std.fmt.allocPrint(allocator, "/api/wiki/pages/{s}/download", .{slug}), true };
    }
    const id = envelope.id orelse return error.InvalidRoute;
    if (!safeSegment(id)) return error.InvalidRoute;
    if (std.mem.eql(u8, action, "paper.delete")) return .{ .DELETE, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}", .{id}), false };
    if (std.mem.eql(u8, action, "paper.addQuestion")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}/questions", .{id}), false };
    if (std.mem.eql(u8, action, "provider.test")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/providers/{s}/test", .{id}), false };
    if (std.mem.eql(u8, action, "provider.disconnect")) return .{ .DELETE, try std.fmt.allocPrint(allocator, "/api/providers/{s}", .{id}), false };
    const child = envelope.child_id orelse return error.InvalidRoute;
    if (!safeSegment(child)) return error.InvalidRoute;
    if (std.mem.eql(u8, action, "paper.updateQuestion")) return .{ .PATCH, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}/questions/{s}", .{ id, child }), false };
    if (std.mem.eql(u8, action, "paper.deleteQuestion")) return .{ .DELETE, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}/questions/{s}", .{ id, child }), false };
    return error.InvalidRoute;
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    if (lib.m3.isExplicitDemo(req)) return mer.badRequest("mutations are unavailable in demo mode");
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    if (lib.mutation.guard(req, 15 * 1024 * 1024)) |response| return response;
    const parsed = std.json.parseFromSlice(Envelope, req.allocator, req.body, .{ .ignore_unknown_fields = false }) catch return mer.badRequest("invalid mutation request");
    const target = route(req.allocator, parsed.value) catch return mer.badRequest("unknown mutation action");
    if (!target[2] and (parsed.value.idempotency_key.len < 16 or !safeSegment(parsed.value.idempotency_key))) return mer.badRequest("invalid idempotency key");
    const body = payloadJson(req.allocator, parsed.value.payload) catch return mer.badRequest("invalid mutation payload");
    const result = lib.backend.proxy(req.allocator, session.token, parsed.value.idempotency_key, target[0], target[1], body, if (target[2]) 10 * 1024 * 1024 else 2 * 1024 * 1024);
    if (result.status == 0) return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"backend unavailable\"}" };
    if (result.status == 401) {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("session clear failed");
        cookies[0] = lib.session.clearCookie();
        return mer.withCookies(.{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"session expired\"}" }, cookies);
    }
    var response = mer.Response{ .status = @enumFromInt(result.status), .content_type = .json, .body = result.body };
    if (target[2] and result.status >= 200 and result.status < 300) {
        const is_page = std.mem.eql(u8, parsed.value.action, "page.download");
        const expected_type = if (is_page) "text/markdown" else "application/zip";
        if (!std.ascii.eqlIgnoreCase(mediaType(result.content_type), expected_type)) return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"invalid export content type\"}" };
        const disposition = canonicalDisposition(req.allocator, result.content_disposition) orelse return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"invalid export filename\"}" };
        const headers = req.allocator.alloc(std.http.Header, 2) catch return mer.internalError("download headers failed");
        headers[0] = .{ .name = "content-disposition", .value = disposition };
        headers[1] = .{ .name = "x-content-type-options", .value = "nosniff" };
        response.content_type = if (is_page) .markdown else .zip;
        response.headers = headers;
    }
    return response;
}

test "M3 proxy allowlist rejects arbitrary paths" {
    try std.testing.expectError(error.InvalidRoute, route(std.testing.allocator, .{ .action = "fetch", .idempotency_key = "12345678-1234-1234-1234-123456789012", .id = "https://evil.example" }));
}
