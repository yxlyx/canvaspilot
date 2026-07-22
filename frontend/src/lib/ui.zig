// src/lib/ui.zig — tiny helpers for HTML escaping and common UI fragments.
// All public functions return slices allocated from the request allocator
// (which is reset after each request, so they don't need to be freed).

const std = @import("std");
const mer = @import("mer");

/// Escape characters that have meaning in HTML.
pub fn escape(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (src) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(c),
        }
    }
    return out.written();
}

/// Escape untrusted display text without ever falling back to the raw value.
/// Allocation failure renders an empty value rather than unsafe HTML.
pub fn escapeSafe(allocator: std.mem.Allocator, src: []const u8) []const u8 {
    return escape(allocator, src) catch "";
}

/// Wrap a list of children inside <ul class="cp-list">…</ul>.
pub fn buildHtml(allocator: std.mem.Allocator) std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.init(allocator);
}

pub fn htmlResponse(buf: *std.Io.Writer.Allocating) mer.Response {
    return mer.html(buf.written());
}
