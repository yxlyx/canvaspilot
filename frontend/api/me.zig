// api/me.zig — small session check. Returns the user JSON when signed in,
// or 401 with an empty body. Useful for client-side checks if we add any.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) {
        return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    }
    const result = lib.backend.me(req.allocator, session.token);
    if (result.value) |v| {
        return mer.typedJson(req.allocator, v.value);
    }
    // Fall back to mock data so the demo still answers consistently.
    return mer.typedJson(req.allocator, lib.mock.me);
}
