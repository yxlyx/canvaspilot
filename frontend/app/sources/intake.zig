const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Source intake" };

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const enrollment_id = req.queryParam("enrollment_id") orelse return mer.badRequest("missing enrollment context");
    const topic_id = req.queryParam("topic_id") orelse return mer.badRequest("missing topic context");
    if (!safeUuid(enrollment_id) or !safeUuid(topic_id)) return mer.badRequest("invalid source guidance context");
    const target = std.fmt.allocPrint(req.allocator, "/sources?enrollment_id={s}&topic_id={s}{s}", .{ enrollment_id, topic_id, if (lib.m3.isExplicitDemo(req)) "&mock=1" else "" }) catch return mer.internalError("source intake redirect failed");
    return mer.redirect(target, .see_other);
}

test "source intake context requires UUIDs" {
    try std.testing.expect(safeUuid("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expect(!safeUuid("topic/../other"));
}
