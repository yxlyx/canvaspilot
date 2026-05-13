// api/auth/start.zig — bounce the user to the FastAPI Canvas OAuth start
// endpoint. Keeping this as a frontend-owned route gives us a stable URL
// the UI can link to even when the backend host changes.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Connecting to Canvas" };

pub fn render(req: mer.Request) mer.Response {
    const url = lib.backend.oauthStartUrl(req.allocator);
    return mer.redirect(url, .see_other);
}
