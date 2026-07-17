// api/sync.zig — POST handler that asks the backend to refresh Canvas data.
// We do it server-side so the HttpOnly session cookie can be attached. On
// failure we still redirect back to the dashboard with a query flag so the
// page can surface a banner instead of crashing.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) {
        return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    }

    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) {
        return mer.redirect("/login", .see_other);
    }
    const result = lib.backend.triggerSync(req.allocator, session.token);
    const target: []const u8 = if (result.value != null) "/dashboard?synced=1" else "/dashboard?sync_failed=1";
    return mer.redirect(target, .see_other);
}
