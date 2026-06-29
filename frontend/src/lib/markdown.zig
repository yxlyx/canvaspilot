// src/lib/markdown.zig — minimal Markdown -> HTML renderer for the subset
// emitted by the backend wiki compiler (app/services/wiki.py).
//
// Supports block-level headings (#, ##), blockquotes (>), unordered lists
// (- ), and footnote reference definition blocks ([^key]: ...). Inline spans
// cover [[wikilinks]], `code`, and [^citation] refs, with all literal text
// HTML-escaped. Everything else falls back to a <p> paragraph.

const std = @import("std");
const ui = @import("ui.zig");

/// Render a wiki markdown document into HTML on the given writer.
pub fn renderMarkdown(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    markdown: []const u8,
) !void {
    var blocks = std.mem.splitSequence(u8, markdown, "\n\n");
    while (blocks.next()) |raw_block| {
        const block = std.mem.trim(u8, raw_block, " \n\r\t");
        if (block.len == 0) continue;

        if (std.mem.startsWith(u8, block, "# ")) {
            const text = std.mem.trim(u8, block[2..], " ");
            try w.writeAll("    <h1>");
            try renderInline(allocator, w, text);
            try w.writeAll("</h1>\n");
        } else if (std.mem.startsWith(u8, block, "## ")) {
            const text = std.mem.trim(u8, block[3..], " ");
            try w.writeAll("    <h2>");
            try renderInline(allocator, w, text);
            try w.writeAll("</h2>\n");
        } else if (std.mem.startsWith(u8, block, "> ")) {
            const text = std.mem.trim(u8, block[2..], " ");
            try w.writeAll("    <blockquote>");
            try renderInline(allocator, w, text);
            try w.writeAll("</blockquote>\n");
        } else if (isListBlock(block)) {
            try renderListBlock(allocator, w, block);
        } else if (isRefBlock(block)) {
            try renderRefBlock(allocator, w, block);
        } else {
            try w.writeAll("    <p>");
            try renderInline(allocator, w, block);
            try w.writeAll("</p>\n");
        }
    }
}

/// Emit an escaped plain-text run.
fn emitRun(allocator: std.mem.Allocator, w: *std.Io.Writer, run: []const u8) !void {
    if (run.len == 0) return;
    const safe = ui.escape(allocator, run) catch run;
    try w.writeAll(safe);
}

/// Render inline markdown spans (`[[wikilinks]]`, `code`, `[^citations]`)
/// into HTML, escaping all literal text.
pub fn renderInline(allocator: std.mem.Allocator, w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    var run_start: usize = 0;
    while (i < text.len) {
        // Wikilink: [[Title]] -> <a href="/wiki/{slug}">Title</a>
        if (i + 1 < text.len and text[i] == '[' and text[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, text, i + 2, "]]")) |end| {
                try emitRun(allocator, w, text[run_start..i]);
                const title = text[i + 2 .. end];
                const slug = slugify(allocator, title);
                const safe_title = ui.escape(allocator, title) catch title;
                try w.print("<a href=\"/wiki/{s}\">{s}</a>", .{ slug, safe_title });
                i = end + 2;
                run_start = i;
                continue;
            }
        }
        // Inline code: `code` -> <code>code</code>
        if (text[i] == '`') {
            if (std.mem.indexOfPos(u8, text, i + 1, "`")) |end| {
                try emitRun(allocator, w, text[run_start..i]);
                const code = text[i + 1 .. end];
                const safe_code = ui.escape(allocator, code) catch code;
                try w.print("<code>{s}</code>", .{safe_code});
                i = end + 1;
                run_start = i;
                continue;
            }
        }
        // Footnote citation ref: [^c1] -> <sup class="cp-cite">c1</sup>
        if (i + 1 < text.len and text[i] == '[' and text[i + 1] == '^') {
            if (std.mem.indexOfPos(u8, text, i + 2, "]")) |end| {
                try emitRun(allocator, w, text[run_start..i]);
                const key = text[i + 2 .. end];
                const safe_key = ui.escape(allocator, key) catch key;
                try w.print("<sup class=\"cp-cite\">{s}</sup>", .{safe_key});
                i = end + 1;
                run_start = i;
                continue;
            }
        }
        i += 1;
    }
    try emitRun(allocator, w, text[run_start..]);
}

/// Replicate the backend slugify: lowercase, collapse non-[a-z0-9] runs to
/// '-', strip leading/trailing '-', fall back to "page".
pub fn slugify(allocator: std.mem.Allocator, title: []const u8) []const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const ow = &out.writer;
    var prev_dash = true;
    for (title) |c| {
        const lower = switch (c) {
            'A'...'Z' => c + 32,
            else => c,
        };
        switch (lower) {
            'a'...'z', '0'...'9' => {
                ow.writeByte(lower) catch break;
                prev_dash = false;
            },
            else => {
                if (!prev_dash) {
                    ow.writeByte('-') catch break;
                    prev_dash = true;
                }
            },
        }
    }
    var slug = out.written();
    while (slug.len > 0 and slug[slug.len - 1] == '-') {
        slug = slug[0 .. slug.len - 1];
    }
    if (slug.len == 0) return "page";
    return slug;
}

fn isListBlock(block: []const u8) bool {
    var lines = std.mem.splitScalar(u8, block, '\n');
    var saw = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "- ")) return false;
        saw = true;
    }
    return saw;
}

fn renderListBlock(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    block: []const u8,
) !void {
    try w.writeAll("    <ul>\n");
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const item = if (std.mem.startsWith(u8, line, "- ")) line[2..] else line;
        try w.writeAll("      <li>");
        try renderInline(allocator, w, item);
        try w.writeAll("</li>\n");
    }
    try w.writeAll("    </ul>\n");
}

fn isRefBlock(block: []const u8) bool {
    var lines = std.mem.splitScalar(u8, block, '\n');
    var saw = false;
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "[^")) return false;
        if (std.mem.indexOf(u8, line, "]: ") == null) return false;
        saw = true;
    }
    return saw;
}

fn renderRefBlock(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    block: []const u8,
) !void {
    try w.writeAll("    <ul class=\"cp-refs\">\n");
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        try w.writeAll("      <li>");
        if (std.mem.indexOf(u8, line, "]: ")) |ke| {
            const key = if (std.mem.startsWith(u8, line, "[^")) line[2..ke] else line[0..ke];
            const body = line[ke + 3 ..];
            try w.writeAll("<span class=\"cp-ref-key\">[");
            try renderInline(allocator, w, key);
            try w.writeAll("]</span> ");
            try renderInline(allocator, w, body);
        } else {
            try renderInline(allocator, w, line);
        }
        try w.writeAll("</li>\n");
    }
    try w.writeAll("    </ul>\n");
}
