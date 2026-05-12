// src/lib/types.zig — Zig structs mirroring the FastAPI Pydantic schemas in
// backend/app/schemas/*. Field names and types match exactly so std.json
// parseFromSlice can deserialize backend responses straight into these.

pub const User = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    canvas_user_id: i64,
};

pub const Module = struct {
    id: []const u8,
    name: []const u8,
    code: []const u8,
    term: []const u8,
    last_synced_at: ?[]const u8 = null,
};

pub const Announcement = struct {
    id: []const u8,
    module_id: []const u8,
    title: []const u8,
    content: []const u8,
    posted_at: []const u8,
    summary: ?[]const u8 = null,
};

pub const Assignment = struct {
    id: []const u8,
    module_id: []const u8,
    title: []const u8,
    due_at: ?[]const u8,
    points_possible: ?f64,
};

pub const Task = struct {
    id: []const u8,
    module_id: []const u8,
    title: []const u8,
    task_type: []const u8,
    due_at: ?[]const u8,
    completed: bool,
    source_url: []const u8,
};

pub const Citation = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    citations: ?[]const Citation = null,
};

pub const ChatRequest = struct {
    module_id: ?[]const u8 = null,
    message: []const u8,
    history: []const ChatMessage = &.{},
};

pub const SyncStatus = struct {
    status: []const u8,
};
