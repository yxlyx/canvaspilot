const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const SourceCreate = struct {
    source_type: []const u8,
    origin: []const u8,
    title: []const u8,
    source_url: []const u8 = "",
    course_context: ?[]const u8 = null,
};

fn validSourceType(value: []const u8) bool {
    return std.mem.eql(u8, value, "markdown") or
        std.mem.eql(u8, value, "plain_text") or
        std.mem.eql(u8, value, "pdf") or
        std.mem.eql(u8, value, "link") or
        std.mem.eql(u8, value, "repository");
}

fn isJsonContentType(value: []const u8) bool {
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value[0..separator], " \t"), "application/json");
}

const Origin = struct {
    scheme: []const u8,
    authority: []const u8,
};

fn parseOrigin(value: []const u8) ?Origin {
    const scheme_end = std.mem.indexOf(u8, value, "://") orelse return null;
    const scheme = value[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
    const authority = value[scheme_end + 3 ..];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "/?#@") != null) return null;
    return .{ .scheme = scheme, .authority = authority };
}

fn sameOrigin(left: Origin, right: Origin) bool {
    return std.ascii.eqlIgnoreCase(left.scheme, right.scheme) and
        std.ascii.eqlIgnoreCase(left.authority, right.authority);
}

fn validPortSuffix(suffix: []const u8) bool {
    if (suffix.len == 0) return true;
    if (suffix[0] != ':' or suffix.len == 1) return false;
    const port = std.fmt.parseInt(u16, suffix[1..], 10) catch return false;
    return port > 0;
}

fn isLoopbackAuthority(authority: []const u8) bool {
    if (std.mem.startsWith(u8, authority, "[::1]")) {
        return validPortSuffix(authority["[::1]".len..]);
    }
    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..colon];
    return (std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1")) and
        validPortSuffix(authority[colon..]);
}

fn isSameOrigin(req: mer.Request, public_origin: ?[]const u8) bool {
    const fetch_site = req.header("sec-fetch-site") orelse return false;
    if (!std.ascii.eqlIgnoreCase(fetch_site, "same-origin")) return false;
    const request_origin = parseOrigin(req.header("origin") orelse return false) orelse return false;

    if (public_origin) |configured| {
        const expected = parseOrigin(configured) orelse return false;
        return sameOrigin(request_origin, expected);
    }

    const host = req.header("host") orelse return false;
    return std.ascii.eqlIgnoreCase(request_origin.scheme, "http") and
        isLoopbackAuthority(host) and
        std.ascii.eqlIgnoreCase(request_origin.authority, host);
}

fn mutationAllowedForOrigin(req: mer.Request, public_origin: ?[]const u8) bool {
    return isJsonContentType(req.header("content-type") orelse "") and isSameOrigin(req, public_origin);
}

fn mutationAllowed(req: mer.Request) bool {
    return lib.mutation.guard(req, 64 * 1024) == null;
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) {
        return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    }
    if (lib.m3.isExplicitDemo(req)) {
        return mer.badRequest("source mutations are unavailable in demo mode");
    }

    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) {
        return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    }
    if (!mutationAllowed(req)) {
        return .{ .status = .forbidden, .content_type = .json, .body = "{\"error\":\"cross-site mutation rejected\"}" };
    }
    if (req.body.len == 0 or req.body.len > 64 * 1024) {
        return mer.badRequest("expected source JSON");
    }

    const parsed = std.json.parseFromSlice(SourceCreate, req.allocator, req.body, .{}) catch {
        return mer.badRequest("invalid source JSON");
    };
    const payload = parsed.value;
    if (!validSourceType(payload.source_type) or payload.origin.len == 0 or payload.title.len == 0) {
        return mer.badRequest("invalid source");
    }

    const result = lib.backend.createSource(req.allocator, session.token, payload);
    if (result.value) |source| {
        var response = mer.typedJson(req.allocator, source.value);
        response.status = @enumFromInt(result.status);
        return response;
    }
    if (result.status >= 400 and result.status < 500) {
        return .{
            .status = @enumFromInt(result.status),
            .content_type = .json,
            .body = "{\"error\":\"source mutation rejected\"}",
        };
    }
    return .{
        .status = .bad_gateway,
        .content_type = .json,
        .body = "{\"error\":\"source mutation failed\"}",
    };
}

fn requestWithHeaders(headers: []const mer.Header) mer.Request {
    var req = mer.Request.init(std.testing.allocator, .POST, "/api/sources");
    req.headers = headers;
    return req;
}

test "source mutation accepts configured direct and proxied origins" {
    const direct = requestWithHeaders(&.{
        .{ .name = "Host", .value = "app.example.com" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "https://app.example.com" },
        .{ .name = "Sec-Fetch-Site", .value = "same-origin" },
    });
    try std.testing.expect(mutationAllowedForOrigin(direct, "https://app.example.com"));

    const proxied = requestWithHeaders(&.{
        .{ .name = "Host", .value = "frontend:3000" },
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "Origin", .value = "https://study.example.com" },
        .{ .name = "Sec-Fetch-Site", .value = "same-origin" },
        .{ .name = "Forwarded", .value = "host=study.example.com;proto=https" },
        .{ .name = "X-Forwarded-Host", .value = "study.example.com" },
    });
    try std.testing.expect(mutationAllowedForOrigin(proxied, "https://study.example.com"));
}

test "source mutation only derives unconfigured loopback HTTP origins" {
    const local = requestWithHeaders(&.{
        .{ .name = "Host", .value = "127.0.0.1:3000" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "http://127.0.0.1:3000" },
        .{ .name = "Sec-Fetch-Site", .value = "same-origin" },
    });
    try std.testing.expect(mutationAllowedForOrigin(local, null));

    const public = requestWithHeaders(&.{
        .{ .name = "Host", .value = "app.example.com" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "http://app.example.com" },
        .{ .name = "Sec-Fetch-Site", .value = "same-origin" },
    });
    try std.testing.expect(!mutationAllowedForOrigin(public, null));
}

test "source mutation fails closed and ignores forwarded origins" {
    const req = requestWithHeaders(&.{
        .{ .name = "Host", .value = "frontend:3000" },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "https://evil.example.com" },
        .{ .name = "Sec-Fetch-Site", .value = "same-origin" },
        .{ .name = "Forwarded", .value = "host=study.example.com;proto=https" },
        .{ .name = "X-Forwarded-Host", .value = "study.example.com" },
        .{ .name = "X-Forwarded-Proto", .value = "https" },
    });
    try std.testing.expect(!mutationAllowedForOrigin(req, "https://study.example.com"));
    try std.testing.expect(!mutationAllowedForOrigin(req, "not-an-origin"));
    try std.testing.expect(!mutationAllowedForOrigin(req, ""));
}

test "source mutation requires JSON and browser same-origin metadata" {
    const wrong_content_type = requestWithHeaders(&.{
        .{ .name = "Content-Type", .value = "text/plain" },
        .{ .name = "Origin", .value = "https://app.example.com" },
        .{ .name = "Sec-Fetch-Site", .value = "same-origin" },
    });
    try std.testing.expect(!mutationAllowedForOrigin(wrong_content_type, "https://app.example.com"));

    const wrong_fetch_site = requestWithHeaders(&.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Origin", .value = "https://app.example.com" },
        .{ .name = "Sec-Fetch-Site", .value = "same-site" },
    });
    try std.testing.expect(!mutationAllowedForOrigin(wrong_fetch_site, "https://app.example.com"));
}
