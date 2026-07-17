// src/lib/config.zig — runtime configuration. Reads optional env vars but
// always has sensible defaults so the app boots without a .env file.

const std = @import("std");
const mer = @import("mer");

pub const Config = struct {
    /// FastAPI backend base URL — e.g. http://localhost:8000.
    backend_url: []const u8,
    /// Name of the HttpOnly cookie that stores the app JWT.
    session_cookie: []const u8,
    /// Set to true to allow ?mock=1 to short-circuit backend calls during
    /// local development and demos.
    mock_enabled: bool,
};

pub fn load() Config {
    return .{
        .backend_url = mer.env("WIKIBASE_BACKEND_URL") orelse "http://localhost:8000",
        .session_cookie = mer.env("WIKIBASE_SESSION_COOKIE") orelse "cp_session",
        .mock_enabled = true,
    };
}
