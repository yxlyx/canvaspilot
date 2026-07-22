// fetch.zig — SSR HTTP client (single + parallel fetch).

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");

/// Options for a single HTTP request made during server-side rendering.
pub const FetchRequest = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    headers: []const std.http.Header = &.{},
    /// Reject response bodies larger than this many bytes. Null is unlimited.
    max_response_bytes: ?usize = null,
};

/// Response from an HTTP fetch. Owns the body — call `deinit()` when done.
pub const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,
    content_type: ?[]u8 = null,
    content_disposition: ?[]u8 = null,

    pub fn deinit(self: FetchResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.content_type) |value| allocator.free(value);
        if (self.content_disposition) |value| allocator.free(value);
    }
};

// ── Freestanding (Workers) two-phase fetch state ─────────────────────────────

const wasm_alloc = if (builtin.os.tag == .freestanding)
    std.heap.wasm_allocator
else
    @as(std.mem.Allocator, undefined);

var wasm_collect_mode: bool = false;
var wasm_collected_urls: std.ArrayListUnmanaged([]const u8) = .empty;
var wasm_fetch_cache: std.StringHashMapUnmanaged([]const u8) = .{};
var wasm_urls_buf: []const u8 = "";

/// Begin URL collection pass. fetchAll() will record URLs instead of fetching.
pub fn wasmBeginCollect() void {
    wasm_collect_mode = true;
    wasm_collected_urls.clearRetainingCapacity();
}

/// End collection pass. Returns newline-delimited URL list (WASM memory).
pub fn wasmEndCollect() []const u8 {
    wasm_collect_mode = false;
    if (wasm_urls_buf.len > 0) wasm_alloc.free(wasm_urls_buf);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (wasm_collected_urls.items) |url| {
        buf.appendSlice(wasm_alloc, url) catch {};
        buf.append(wasm_alloc, '\n') catch {};
    }
    wasm_urls_buf = buf.toOwnedSlice(wasm_alloc) catch "";
    return wasm_urls_buf;
}

/// Store a pre-fetched result (called by JS before the render pass).
pub fn wasmProvideResult(url: []const u8, body: []const u8) void {
    const u = wasm_alloc.dupe(u8, url) catch return;
    const b = wasm_alloc.dupe(u8, body) catch return;
    wasm_fetch_cache.put(wasm_alloc, u, b) catch {};
}

/// Clear the fetch cache after rendering.
pub fn wasmClearCache() void {
    wasm_fetch_cache.clearRetainingCapacity();
}

/// Make an HTTP request from a server-side page handler.
pub fn fetch(allocator: std.mem.Allocator, opts: FetchRequest) !FetchResponse {
    if (comptime builtin.os.tag == .freestanding) return error.NotSupported;
    // Use shared runtime.io instead of creating new Threaded instance
    var client = std.http.Client{ .allocator = allocator, .io = runtime.io };
    defer client.deinit();

    const uri = try std.Uri.parse(opts.url);
    var req = try client.request(opts.method, uri, .{ .extra_headers = opts.headers, .redirect_behavior = .unhandled });
    defer req.deinit();
    if (opts.body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var request_body = try req.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(payload);
        try request_body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [16 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const content_type = if (response.head.content_type) |value| try allocator.dupe(u8, value) else null;
    errdefer if (content_type) |value| allocator.free(value);
    const content_disposition = if (response.head.content_disposition) |value| try allocator.dupe(u8, value) else null;
    errdefer if (content_disposition) |value| allocator.free(value);
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const owned = if (opts.max_response_bytes) |max_bytes|
        try reader.allocRemaining(allocator, .limited(max_bytes))
    else
        try reader.allocRemaining(allocator, .unlimited);
    return .{ .status = response.head.status, .body = owned, .content_type = content_type, .content_disposition = content_disposition };
}

fn fetchWorker(allocator: std.mem.Allocator, opts: FetchRequest, out: *?FetchResponse) void {
    out.* = fetch(allocator, opts) catch null;
}

fn joinSpawned(threads: []?std.Thread) void {
    for (threads) |thread| if (thread) |spawned| spawned.join();
}

fn noopWorker() void {}

test "partial thread spawn joins only initialized handles" {
    var threads = [_]?std.Thread{ null, try std.Thread.spawn(.{}, noopWorker, .{}), null };
    joinSpawned(&threads);
}

/// Fetch multiple URLs in parallel. Returns results in the same order as inputs.
pub fn fetchAll(allocator: std.mem.Allocator, requests: []const FetchRequest) []?FetchResponse {
    const results = allocator.alloc(?FetchResponse, requests.len) catch return &.{};
    @memset(results, null);

    if (comptime builtin.os.tag == .freestanding) {
        if (wasm_collect_mode) {
            for (requests) |req_opts| {
                const url = wasm_alloc.dupe(u8, req_opts.url) catch continue;
                wasm_collected_urls.append(wasm_alloc, url) catch {};
            }
        } else {
            for (requests, 0..) |req_opts, i| {
                if (wasm_fetch_cache.get(req_opts.url)) |body| {
                    results[i] = .{ .status = .ok, .body = @constCast(body) };
                }
            }
        }
        return results;
    }

    if (comptime builtin.single_threaded) {
        for (requests, 0..) |req_opts, i| {
            results[i] = fetch(allocator, req_opts) catch null;
        }
        return results;
    }

    if (requests.len == 1) {
        results[0] = fetch(allocator, requests[0]) catch null;
        return results;
    }

    const threads = allocator.alloc(?std.Thread, requests.len) catch return results;
    defer allocator.free(threads);
    @memset(threads, null);

    const gpas = allocator.alloc(std.heap.DebugAllocator(.{}), requests.len) catch return results;
    defer allocator.free(gpas);
    for (gpas) |*g| g.* = .init;

    for (requests, 0..) |req_opts, i| {
        threads[i] = std.Thread.spawn(.{}, fetchWorker, .{ gpas[i].allocator(), req_opts, &results[i] }) catch {
            results[i] = null;
            continue;
        };
    }

    joinSpawned(threads);

    for (results, 0..) |*r, i| {
        if (r.*) |resp| {
            const owned = allocator.dupe(u8, resp.body) catch {
                resp.deinit(gpas[i].allocator());
                r.* = null;
                continue;
            };
            const content_type = if (resp.content_type) |value| allocator.dupe(u8, value) catch null else null;
            const content_disposition = if (resp.content_disposition) |value| allocator.dupe(u8, value) catch null else null;
            r.* = .{ .status = resp.status, .body = owned, .content_type = content_type, .content_disposition = content_disposition };
            resp.deinit(gpas[i].allocator());
        }
        _ = gpas[i].deinit();
    }

    return results;
}
