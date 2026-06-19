// src/lib/backend.zig — thin server-side HTTP client around mer.fetch that
// talks to the FastAPI backend. Always returns Result(T) so call-sites can
// gracefully fall back to mock data on failure.

const std = @import("std");
const mer = @import("mer");
const types = @import("types.zig");
const config = @import("config.zig");

pub fn Result(comptime T: type) type {
    return struct {
        status: u16,
        value: ?std.json.Parsed(T) = null,
        err: ?[]const u8 = null,
    };
}

fn authHeader(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
}

fn buildUrl(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const cfg = config.load();
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ cfg.backend_url, path });
}

fn parsed(comptime T: type, allocator: std.mem.Allocator, body: []const u8) ?std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true }) catch null;
}

fn requestJson(
    comptime T: type,
    allocator: std.mem.Allocator,
    token: []const u8,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
) Result(T) {
    const url = buildUrl(allocator, path) catch {
        return .{ .status = 0, .err = "could not build url" };
    };
    const bearer = authHeader(allocator, token) catch {
        return .{ .status = 0, .err = "could not build auth header" };
    };

    var headers_buf: [4]std.http.Header = undefined;
    var n: usize = 0;
    headers_buf[n] = .{ .name = "Authorization", .value = bearer };
    n += 1;
    headers_buf[n] = .{ .name = "Accept", .value = "application/json" };
    n += 1;
    if (body != null) {
        headers_buf[n] = .{ .name = "Content-Type", .value = "application/json" };
        n += 1;
    }

    const res = mer.fetch(allocator, .{
        .url = url,
        .method = method,
        .body = body,
        .headers = headers_buf[0..n],
    }) catch |e| {
        return .{ .status = 0, .err = @errorName(e) };
    };

    const status_int: u16 = @intFromEnum(res.status);
    if (status_int >= 400) {
        return .{ .status = status_int, .err = "non-2xx response" };
    }
    return .{ .status = status_int, .value = parsed(T, allocator, res.body) };
}

fn requestJsonNoAuth(
    comptime T: type,
    allocator: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    body: []const u8,
) Result(T) {
    const url = buildUrl(allocator, path) catch {
        return .{ .status = 0, .err = "could not build url" };
    };

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/json" },
    };

    const res = mer.fetch(allocator, .{
        .url = url,
        .method = method,
        .body = body,
        .headers = &headers,
    }) catch |e| {
        return .{ .status = 0, .err = @errorName(e) };
    };

    const status_int: u16 = @intFromEnum(res.status);
    if (status_int >= 400) {
        return .{ .status = status_int, .err = res.body };
    }
    return .{ .status = status_int, .value = parsed(T, allocator, res.body) };
}

const RegisterPayload = struct {
    name: []const u8,
    email: []const u8,
    password: []const u8,
};

const LoginPayload = struct {
    email: []const u8,
    password: []const u8,
};

fn stringify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return out.written();
}

// ── High-level endpoints ────────────────────────────────────────────────────

pub fn register(
    allocator: std.mem.Allocator,
    name: []const u8,
    email: []const u8,
    password: []const u8,
) Result(types.TokenResponse) {
    const body = stringify(allocator, RegisterPayload{
        .name = name,
        .email = email,
        .password = password,
    }) catch {
        return .{ .status = 0, .err = "could not encode request" };
    };
    return requestJsonNoAuth(types.TokenResponse, allocator, .POST, "/api/auth/register", body);
}

pub fn login(
    allocator: std.mem.Allocator,
    email: []const u8,
    password: []const u8,
) Result(types.TokenResponse) {
    const body = stringify(allocator, LoginPayload{ .email = email, .password = password }) catch {
        return .{ .status = 0, .err = "could not encode request" };
    };
    return requestJsonNoAuth(types.TokenResponse, allocator, .POST, "/api/auth/login", body);
}

pub fn me(allocator: std.mem.Allocator, token: []const u8) Result(types.User) {
    return requestJson(types.User, allocator, token, .GET, "/api/auth/me", null);
}

pub fn listModules(allocator: std.mem.Allocator, token: []const u8) Result([]types.Module) {
    return requestJson([]types.Module, allocator, token, .GET, "/api/modules", null);
}

pub fn getModule(allocator: std.mem.Allocator, token: []const u8, id: []const u8) Result(types.Module) {
    const path = std.fmt.allocPrint(allocator, "/api/modules/{s}", .{id}) catch {
        return .{ .status = 0, .err = "alloc" };
    };
    return requestJson(types.Module, allocator, token, .GET, path, null);
}

pub fn moduleAnnouncements(
    allocator: std.mem.Allocator,
    token: []const u8,
    id: []const u8,
) Result([]types.Announcement) {
    const path = std.fmt.allocPrint(allocator, "/api/modules/{s}/announcements", .{id}) catch {
        return .{ .status = 0, .err = "alloc" };
    };
    return requestJson([]types.Announcement, allocator, token, .GET, path, null);
}

pub fn upcomingTasks(allocator: std.mem.Allocator, token: []const u8) Result([]types.Task) {
    return requestJson([]types.Task, allocator, token, .GET, "/api/tasks/upcoming", null);
}

pub fn triggerSync(allocator: std.mem.Allocator, token: []const u8) Result(types.SyncStatus) {
    return requestJson(types.SyncStatus, allocator, token, .POST, "/api/modules/sync", "{}");
}
