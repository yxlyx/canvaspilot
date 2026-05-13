const std = @import("std");

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn decode(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (raw[i] == '%' and i + 2 < raw.len) {
            if (hexValue(raw[i + 1])) |hi| {
                if (hexValue(raw[i + 2])) |lo| {
                    try out.append(allocator, (hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
            try out.append(allocator, raw[i]);
            i += 1;
        } else {
            try out.append(allocator, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn value(allocator: std.mem.Allocator, body: []const u8, name: []const u8) !?[]const u8 {
    var parts = std.mem.splitScalar(u8, body, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = try decode(allocator, part[0..eq]);
        if (std.mem.eql(u8, key, name)) {
            return try decode(allocator, part[eq + 1 ..]);
        }
    }
    return null;
}

test "form value decodes url encoded data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body = "email=test%40example.com&name=Demo+User";
    const email = (try value(allocator, body, "email")).?;
    const name = (try value(allocator, body, "name")).?;
    try std.testing.expectEqualStrings("test@example.com", email);
    try std.testing.expectEqualStrings("Demo User", name);
}
