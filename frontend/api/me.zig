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
        return lib.m3.privateForSession(req, mer.typedJson(req.allocator, v.value));
    }
    if (result.status == 401) {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("session clear failed");
        cookies[0] = lib.session.clearCookie();
        return lib.m3.privateForSession(req, mer.withCookies(.{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" }, cookies));
    }
    return lib.m3.privateForSession(req, .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"identity service unavailable\"}" });
}
