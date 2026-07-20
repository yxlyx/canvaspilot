// src/lib/backend.zig — thin server-side HTTP client around mer.fetch that
// talks to the FastAPI backend. Always returns Result(T) so live call-sites
// can render explicit unavailable/error states without fixture fallback.

const std = @import("std");
const mer = @import("mer");
const types = @import("types.zig");
const config = @import("config.zig");

const max_response_bytes = 8 * 1024 * 1024;

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
        .max_response_bytes = max_response_bytes,
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
        .max_response_bytes = max_response_bytes,
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

pub fn listSources(allocator: std.mem.Allocator, token: []const u8) Result([]types.SourceResponse) {
    return requestJson([]types.SourceResponse, allocator, token, .GET, "/api/sources", null);
}

pub fn createSource(
    allocator: std.mem.Allocator,
    token: []const u8,
    payload: anytype,
) Result(types.SourceResponse) {
    const body = stringify(allocator, payload) catch {
        return .{ .status = 0, .err = "could not encode request" };
    };
    return requestJson(types.SourceResponse, allocator, token, .POST, "/api/sources", body);
}

pub fn listWikiPages(allocator: std.mem.Allocator, token: []const u8) Result([]types.WikiPageResponse) {
    return requestJson([]types.WikiPageResponse, allocator, token, .GET, "/api/wiki/pages", null);
}

pub fn getWikiPage(
    allocator: std.mem.Allocator,
    token: []const u8,
    slug: []const u8,
) Result(types.WikiPageResponse) {
    const path = std.fmt.allocPrint(allocator, "/api/wiki/pages/{s}", .{slug}) catch {
        return .{ .status = 0, .err = "alloc" };
    };
    return requestJson(types.WikiPageResponse, allocator, token, .GET, path, null);
}

pub fn listFlashcardDecks(
    allocator: std.mem.Allocator,
    token: []const u8,
) Result([]types.FlashcardDeckResponse) {
    return requestJson([]types.FlashcardDeckResponse, allocator, token, .GET, "/api/flashcards/decks", null);
}

pub fn submitFlashcardAttempt(
    allocator: std.mem.Allocator,
    token: []const u8,
    card_id: []const u8,
    is_correct: bool,
    confidence: ?u8,
) Result(types.FlashcardAttemptResponse) {
    const path = std.fmt.allocPrint(allocator, "/api/flashcards/cards/{s}/attempts", .{card_id}) catch {
        return .{ .status = 0, .err = "alloc" };
    };
    const body = stringify(allocator, .{
        .is_correct = is_correct,
        .confidence = confidence,
    }) catch {
        return .{ .status = 0, .err = "could not encode request" };
    };
    return requestJson(types.FlashcardAttemptResponse, allocator, token, .POST, path, body);
}

pub fn triggerSync(allocator: std.mem.Allocator, token: []const u8) Result(types.SyncStatus) {
    return requestJson(types.SyncStatus, allocator, token, .POST, "/api/modules/sync", "{}");
}

pub fn listOutputs(allocator: std.mem.Allocator, token: []const u8, cursor: ?[]const u8) Result(types.StudyOutputPageResponse) {
    const path = if (cursor) |value|
        std.fmt.allocPrint(allocator, "/api/outputs/page?limit=20&cursor={s}", .{value}) catch return .{ .status = 0, .err = "alloc" }
    else
        "/api/outputs/page?limit=20";
    return requestJson(types.StudyOutputPageResponse, allocator, token, .GET, path, null);
}
pub fn getOutput(allocator: std.mem.Allocator, token: []const u8, id: []const u8) Result(types.StudyOutputResponse) {
    const path = std.fmt.allocPrint(allocator, "/api/outputs/{s}", .{id}) catch return .{ .status = 0, .err = "alloc" };
    return requestJson(types.StudyOutputResponse, allocator, token, .GET, path, null);
}
pub fn listHealth(allocator: std.mem.Allocator, token: []const u8) Result([]types.HealthFindingResponse) {
    return requestJson([]types.HealthFindingResponse, allocator, token, .GET, "/api/workspace/health", null);
}
pub fn getHealth(allocator: std.mem.Allocator, token: []const u8, id: []const u8) Result(types.HealthFindingResponse) {
    const path = std.fmt.allocPrint(allocator, "/api/workspace/health/{s}", .{id}) catch return .{ .status = 0, .err = "alloc" };
    return requestJson(types.HealthFindingResponse, allocator, token, .GET, path, null);
}
pub fn history(allocator: std.mem.Allocator, token: []const u8) Result([]types.HistoryEntryResponse) {
    return requestJson([]types.HistoryEntryResponse, allocator, token, .GET, "/api/workspace/history", null);
}
pub fn revisions(allocator: std.mem.Allocator, token: []const u8, page_id: []const u8) Result([]types.WikiRevisionResponse) {
    const path = std.fmt.allocPrint(allocator, "/api/wiki/pages/{s}/revisions", .{page_id}) catch return .{ .status = 0, .err = "alloc" };
    return requestJson([]types.WikiRevisionResponse, allocator, token, .GET, path, null);
}
pub fn revisionDiff(allocator: std.mem.Allocator, token: []const u8, page_id: []const u8, from: usize, to: usize) Result(types.RevisionDiffResponse) {
    const path = std.fmt.allocPrint(allocator, "/api/wiki/pages/{s}/diff?from_revision={d}&to_revision={d}", .{ page_id, from, to }) catch return .{ .status = 0, .err = "alloc" };
    return requestJson(types.RevisionDiffResponse, allocator, token, .GET, path, null);
}
pub fn topicMeters(allocator: std.mem.Allocator, token: []const u8) Result([]types.TopicMeterResponse) {
    return requestJson([]types.TopicMeterResponse, allocator, token, .GET, "/api/meters/topics", null);
}
pub fn listMarkedPapers(allocator: std.mem.Allocator, token: []const u8, cursor: ?[]const u8) Result(types.MarkedPaperPageResponse) {
    const path = if (cursor) |value|
        std.fmt.allocPrint(allocator, "/api/marked-papers/page?limit=20&cursor={s}", .{value}) catch return .{ .status = 0, .err = "alloc" }
    else
        "/api/marked-papers/page?limit=20";
    return requestJson(types.MarkedPaperPageResponse, allocator, token, .GET, path, null);
}
pub fn getMarkedPaper(allocator: std.mem.Allocator, token: []const u8, id: []const u8) Result(types.MarkedPaperResponse) {
    const path = std.fmt.allocPrint(allocator, "/api/marked-papers/{s}", .{id}) catch return .{ .status = 0, .err = "alloc" };
    return requestJson(types.MarkedPaperResponse, allocator, token, .GET, path, null);
}
pub fn providerDescriptors(allocator: std.mem.Allocator, token: []const u8) Result([]types.ProviderDescriptor) {
    return requestJson([]types.ProviderDescriptor, allocator, token, .GET, "/api/providers", null);
}
pub fn providerSettings(allocator: std.mem.Allocator, token: []const u8) Result([]types.ProviderStatusResponse) {
    return requestJson([]types.ProviderStatusResponse, allocator, token, .GET, "/api/providers/settings", null);
}

pub const RawResult = struct {
    status: u16,
    body: []const u8 = "",
    content_type: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    err: ?[]const u8 = null,
};
pub fn proxy(allocator: std.mem.Allocator, token: []const u8, idempotency_key: []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8, max_bytes: usize) RawResult {
    const request_body: ?[]const u8 = if (body == null and method.requestHasBody()) "null" else body;
    const url = buildUrl(allocator, path) catch return .{ .status = 0, .err = "could not build URL" };
    const bearer = authHeader(allocator, token) catch return .{ .status = 0, .err = "could not build authorization" };
    var headers_buf: [4]std.http.Header = undefined;
    headers_buf[0] = .{ .name = "Authorization", .value = bearer };
    headers_buf[1] = .{ .name = "Accept", .value = "application/json, text/markdown, application/zip" };
    var n: usize = 2;
    if (idempotency_key.len > 0) {
        headers_buf[n] = .{ .name = "Idempotency-Key", .value = idempotency_key };
        n += 1;
    }
    if (request_body != null) {
        headers_buf[n] = .{ .name = "Content-Type", .value = "application/json" };
        n += 1;
    }
    const res = mer.fetch(allocator, .{ .url = url, .method = method, .body = request_body, .headers = headers_buf[0..n], .max_response_bytes = max_bytes }) catch |e| return .{ .status = 0, .err = @errorName(e) };
    return .{ .status = @intFromEnum(res.status), .body = res.body, .content_type = res.content_type, .content_disposition = res.content_disposition };
}
