// src/lib/chat.zig — bounded helpers for aggregating backend chat SSE frames.

const std = @import("std");
const types = @import("types.zig");

const TokenEvent = struct { text: []const u8 = "" };
const CitationsEvent = struct { citations: []const types.Citation = &.{} };
const DoneEvent = struct {
    grounded: bool = false,
    confidence: f64 = 0.0,
    message: ?[]const u8 = null,
};

pub const Reply = struct {
    message: []const u8,
    citations: []const types.Citation,
    grounded: bool = true,
    confidence: f64 = 0.0,
    source: []const u8 = "backend",
};

pub fn aggregateSse(allocator: std.mem.Allocator, sse: []const u8) !Reply {
    var message_buf: std.ArrayListUnmanaged(u8) = .empty;
    var citations: []const types.Citation = &.{};
    var grounded = false;
    var confidence: f64 = 0.0;
    var override_message: ?[]const u8 = null;
    var done_seen = false;

    // SSE producers commonly use CRLF. Normalize it so blank-frame splitting
    // behaves identically for `\n\n` and `\r\n\r\n` streams.
    var normalized: std.Io.Writer.Allocating = .init(allocator);
    var index: usize = 0;
    while (index < sse.len) {
        if (sse[index] == '\r' and index + 1 < sse.len and sse[index + 1] == '\n') {
            try normalized.writer.writeByte('\n');
            index += 2;
        } else {
            try normalized.writer.writeByte(sse[index]);
            index += 1;
        }
    }

    var frame_it = std.mem.splitSequence(u8, normalized.written(), "\n\n");
    while (frame_it.next()) |frame| {
        const trimmed = std.mem.trim(u8, frame, "\r\n \t");
        if (trimmed.len == 0) continue;

        var event: []const u8 = "message";
        var data: []const u8 = "";
        var line_it = std.mem.splitScalar(u8, trimmed, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "event:")) {
                event = std.mem.trim(u8, line[6..], " ");
            } else if (std.mem.startsWith(u8, line, "data:")) {
                data = std.mem.trim(u8, line[5..], " ");
            }
        }
        const recognized = std.mem.eql(u8, event, "token") or std.mem.eql(u8, event, "citations") or std.mem.eql(u8, event, "done");
        if (data.len == 0) {
            if (recognized) return error.InvalidSse;
            continue;
        }

        if (std.mem.eql(u8, event, "token")) {
            const parsed = std.json.parseFromSlice(TokenEvent, allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return error.InvalidSse;
            try message_buf.appendSlice(allocator, parsed.value.text);
        } else if (std.mem.eql(u8, event, "citations")) {
            const parsed = std.json.parseFromSlice(CitationsEvent, allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return error.InvalidSse;
            citations = parsed.value.citations;
        } else if (std.mem.eql(u8, event, "done")) {
            const parsed = std.json.parseFromSlice(DoneEvent, allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch return error.InvalidSse;
            grounded = parsed.value.grounded;
            confidence = parsed.value.confidence;
            override_message = parsed.value.message;
            done_seen = true;
        }
    }
    if (!done_seen) return error.InvalidSse;

    const final_message = if (override_message) |message| message else try message_buf.toOwnedSlice(allocator);
    return .{
        .message = if (final_message.len > 0)
            final_message
        else
            "I don't have enough information from your Canvas modules to answer this.",
        .citations = citations,
        .grounded = grounded,
        .confidence = confidence,
    };
}
