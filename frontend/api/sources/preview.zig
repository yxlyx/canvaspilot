const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const max_preview_bytes = 5 * 1024 * 1024;
const private_headers = [_]std.http.Header{
    .{ .name = "cache-control", .value = "private, no-store" },
    .{ .name = "x-content-type-options", .value = "nosniff" },
};

fn previewError(status: std.http.Status, body: []const u8) mer.Response {
    return .{ .status = status, .content_type = .text, .body = body, .headers = &private_headers };
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

fn mediaType(value: ?[]const u8) []const u8 {
    const raw = value orelse return "";
    const separator = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    return std.mem.trim(u8, raw[0..separator], " \t");
}

fn validPng(value: []const u8) bool {
    return value.len >= 8 and std.mem.eql(u8, value[0..8], "\x89PNG\r\n\x1a\n");
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .GET) return previewError(.method_not_allowed, "GET only");
    if (lib.m3.isExplicitDemo(req)) return previewError(.not_found, "preview not found");
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return previewError(.unauthorized, "unauthorized");
    const source_id = req.queryParam("id") orelse return previewError(.bad_request, "missing source identifier");
    if (!safeUuid(source_id)) return previewError(.bad_request, "invalid source identifier");
    const path = std.fmt.allocPrint(req.allocator, "/api/sources/{s}/preview", .{source_id}) catch return previewError(.internal_server_error, "preview request failed");
    const result = lib.backend.proxy(req.allocator, session.token, "", .GET, path, null, max_preview_bytes);
    if (result.status == 404 or result.status == 415) return previewError(.not_found, "preview not found");
    if (result.status == 401) return previewError(.unauthorized, "unauthorized");
    if (result.status == 503) return previewError(.service_unavailable, "preview temporarily unavailable");
    if (result.status < 200 or result.status >= 300) return previewError(.bad_gateway, "preview unavailable");
    if (!std.ascii.eqlIgnoreCase(mediaType(result.content_type), "image/png") or !validPng(result.body)) return previewError(.bad_gateway, "invalid preview");
    return .{ .status = .ok, .content_type = .png, .body = result.body, .headers = &private_headers };
}

test "preview identifiers and PNG responses are bounded" {
    try std.testing.expect(safeUuid("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expect(!safeUuid("../../private"));
    try std.testing.expect(validPng("\x89PNG\r\n\x1a\nbody"));
    try std.testing.expect(!validPng("not a png"));
}
