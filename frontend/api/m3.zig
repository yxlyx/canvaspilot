const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const Envelope = struct {
    action: []const u8,
    idempotency_key: []const u8 = "",
    id: ?[]const u8 = null,
    child_id: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    payload: ?std.json.Value = null,
};
fn safeSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn mediaType(value: ?[]const u8) []const u8 {
    const raw = value orelse return "";
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " \t");
}

fn canonicalDisposition(allocator: std.mem.Allocator, value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (raw.len > 512 or std.mem.indexOfAny(u8, raw, "\r\n") != null) return null;
    var fields = std.mem.splitScalar(u8, raw, ';');
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, fields.first(), " \t"), "attachment")) return null;
    while (fields.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " \t");
        if (trimmed.len < 9 or !std.ascii.eqlIgnoreCase(trimmed[0..9], "filename=")) continue;
        var filename = std.mem.trim(u8, trimmed[9..], " \t");
        if (filename.len >= 2 and filename[0] == '"' and filename[filename.len - 1] == '"') filename = filename[1 .. filename.len - 1];
        if (filename.len == 0 or filename.len > 255) return null;
        for (filename) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return null,
        };
        return std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{filename}) catch null;
    }
    return null;
}

fn payloadJson(allocator: std.mem.Allocator, payload: ?std.json.Value) !?[]const u8 {
    const value = payload orelse return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    var writer: std.json.Stringify = .{ .writer = &out.writer };
    try writer.write(value);
    return out.written();
}

const FormMutation = struct {
    envelope: Envelope,
    body: ?[]const u8,
    redirect_path: []const u8,
};

fn formValue(req: mer.Request, name: []const u8) ?[]const u8 {
    return lib.form.value(req.allocator, req.body, name) catch null;
}

fn requiredFormValue(req: mer.Request, name: []const u8) ![]const u8 {
    const value = formValue(req, name) orelse return error.InvalidForm;
    if (value.len == 0) return error.InvalidForm;
    return value;
}

fn putOptionalString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, value: ?[]const u8) !void {
    if (value) |text| if (text.len > 0) try object.put(allocator, name, .{ .string = text });
}

fn putOptionalFloat(allocator: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, value: ?[]const u8, explicit_null: bool) !void {
    if (value) |text| {
        if (text.len > 0) return object.put(allocator, name, .{ .float = try std.fmt.parseFloat(f64, text) });
    }
    if (explicit_null) try object.put(allocator, name, .null);
}

fn formPayload(req: mer.Request, action: []const u8) !?std.json.Value {
    var object: std.json.ObjectMap = .empty;
    if (std.mem.eql(u8, action, "output.create")) {
        try object.put(req.allocator, "output_type", .{ .string = try requiredFormValue(req, "output_type") });
        try putOptionalString(req.allocator, &object, "title", formValue(req, "title"));
        const scope = try requiredFormValue(req, "scope_type");
        if (std.mem.eql(u8, scope, "source_ids")) {
            var values: std.json.Array = .init(req.allocator);
            try values.append(.{ .string = try requiredFormValue(req, "source_ids") });
            try object.put(req.allocator, "source_ids", .{ .array = values });
        } else if (std.mem.eql(u8, scope, "wiki_page_id")) {
            try object.put(req.allocator, "wiki_page_id", .{ .string = try requiredFormValue(req, "wiki_page_id") });
        } else if (std.mem.eql(u8, scope, "topic")) {
            try object.put(req.allocator, "topic", .{ .string = try requiredFormValue(req, "topic") });
        } else return error.InvalidForm;
    } else if (std.mem.eql(u8, action, "paper.addQuestion") or std.mem.eql(u8, action, "paper.updateQuestion")) {
        if (std.mem.eql(u8, action, "paper.addQuestion")) {
            const question_number = try std.fmt.parseInt(i64, try requiredFormValue(req, "question_number"), 10);
            try object.put(req.allocator, "question_number", .{ .integer = question_number });
        }
        try object.put(req.allocator, "question_text", .{ .string = try requiredFormValue(req, "question_text") });
        try object.put(req.allocator, "topic_tag", .{ .string = try requiredFormValue(req, "topic_tag") });
        try putOptionalString(req.allocator, &object, "feedback", formValue(req, "feedback"));
        try putOptionalFloat(req.allocator, &object, "awarded_marks", formValue(req, "awarded_marks"), std.mem.eql(u8, action, "paper.updateQuestion"));
        try putOptionalFloat(req.allocator, &object, "available_marks", formValue(req, "available_marks"), std.mem.eql(u8, action, "paper.updateQuestion"));
        if (formValue(req, "confidence")) |confidence| try object.put(req.allocator, "confidence", .{ .float = try std.fmt.parseFloat(f64, confidence) });
        if (std.mem.eql(u8, action, "paper.updateQuestion")) try object.put(req.allocator, "reviewed", .{ .bool = formValue(req, "reviewed") != null });
    } else if (std.mem.eql(u8, action, "provider.save")) {
        const provider = try requiredFormValue(req, "provider");
        try object.put(req.allocator, "provider", .{ .string = provider });
        try object.put(req.allocator, "api_key", .{ .string = try requiredFormValue(req, "api_key") });
        try object.put(req.allocator, "model", .{ .string = try requiredFormValue(req, "model") });
        if (!std.mem.eql(u8, provider, "openai") and !std.mem.eql(u8, provider, "google_gemini")) {
            if (formValue(req, "endpoint")) |endpoint| {
                if (endpoint.len > 0) try object.put(req.allocator, "endpoint", .{ .string = endpoint }) else try object.put(req.allocator, "endpoint", .null);
            } else try object.put(req.allocator, "endpoint", .null);
        }
    } else return null;
    return .{ .object = object };
}

fn formMutation(req: mer.Request) !FormMutation {
    const action = try requiredFormValue(req, "action");
    const id = formValue(req, "id");
    const child_id = formValue(req, "child_id");
    const slug = formValue(req, "slug");
    const seed: u64 = @bitCast(lib.time.nowSecs());
    const key = try std.fmt.allocPrint(req.allocator, "form-{x}-{x}", .{ seed, std.hash.Wyhash.hash(seed, req.body) });
    const envelope: Envelope = .{ .action = action, .idempotency_key = key, .id = id, .child_id = child_id, .slug = slug };
    const payload = try formPayload(req, action);
    const body = try payloadJson(req.allocator, payload);
    const redirect_path: []const u8 = if (std.mem.eql(u8, action, "output.create"))
        "/wiki/guides"
    else if (std.mem.eql(u8, action, "health.run"))
        "/sources/health"
    else if (std.mem.startsWith(u8, action, "provider."))
        "/settings/providers"
    else if (std.mem.eql(u8, action, "paper.delete"))
        "/sources/papers"
    else if (std.mem.startsWith(u8, action, "paper.") and id != null and safeSegment(id.?))
        try std.fmt.allocPrint(req.allocator, "/sources/papers/{s}", .{id.?})
    else
        "/sources/papers";
    return .{ .envelope = envelope, .body = body, .redirect_path = redirect_path };
}

fn formRedirect(req: mer.Request, path: []const u8, success: bool) mer.Response {
    const location = std.fmt.allocPrint(req.allocator, "{s}?{s}=1", .{ path, if (success) "saved" else "error" }) catch path;
    return mer.redirect(location, .see_other);
}
fn route(allocator: std.mem.Allocator, envelope: Envelope) !struct { std.http.Method, []const u8, bool } {
    const action = envelope.action;
    if (std.mem.eql(u8, action, "output.create")) return .{ .POST, "/api/outputs", false };
    if (std.mem.eql(u8, action, "health.run")) return .{ .POST, "/api/workspace/health", false };
    if (std.mem.eql(u8, action, "paper.upload")) return .{ .POST, "/api/marked-papers", false };
    if (std.mem.eql(u8, action, "provider.save")) return .{ .PUT, "/api/providers/settings", false };
    if (std.mem.eql(u8, action, "wiki.export")) return .{ .POST, "/api/wiki/download", true };
    if (std.mem.eql(u8, action, "page.download")) {
        const slug = envelope.slug orelse return error.InvalidRoute;
        if (!safeSegment(slug)) return error.InvalidRoute;
        return .{ .GET, try std.fmt.allocPrint(allocator, "/api/wiki/pages/{s}/download", .{slug}), true };
    }
    const id = envelope.id orelse return error.InvalidRoute;
    if (!safeSegment(id)) return error.InvalidRoute;
    if (std.mem.eql(u8, action, "paper.delete")) return .{ .DELETE, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}", .{id}), false };
    if (std.mem.eql(u8, action, "paper.addQuestion")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}/questions", .{id}), false };
    if (std.mem.eql(u8, action, "provider.test")) return .{ .POST, try std.fmt.allocPrint(allocator, "/api/providers/{s}/test", .{id}), false };
    if (std.mem.eql(u8, action, "provider.disconnect")) return .{ .DELETE, try std.fmt.allocPrint(allocator, "/api/providers/{s}", .{id}), false };
    const child = envelope.child_id orelse return error.InvalidRoute;
    if (!safeSegment(child)) return error.InvalidRoute;
    if (std.mem.eql(u8, action, "paper.updateQuestion")) return .{ .PATCH, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}/questions/{s}", .{ id, child }), false };
    if (std.mem.eql(u8, action, "paper.deleteQuestion")) return .{ .DELETE, try std.fmt.allocPrint(allocator, "/api/marked-papers/{s}/questions/{s}", .{ id, child }), false };
    return error.InvalidRoute;
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    if (lib.m3.isExplicitDemo(req)) return mer.badRequest("mutations are unavailable in demo mode");
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"unauthorized\"}" };
    const content_type = mediaType(req.header("content-type"));
    const is_form = std.ascii.eqlIgnoreCase(content_type, "application/x-www-form-urlencoded");
    var parsed_json: ?std.json.Parsed(Envelope) = null;
    const form = if (is_form) formMutation(req) catch return formRedirect(req, "/wiki/guides", false) else null;
    const envelope: Envelope = if (form) |value| value.envelope else blk: {
        if (lib.mutation.guard(req, 15 * 1024 * 1024)) |response| return response;
        parsed_json = std.json.parseFromSlice(Envelope, req.allocator, req.body, .{ .ignore_unknown_fields = false }) catch return mer.badRequest("invalid mutation request");
        break :blk parsed_json.?.value;
    };
    if (is_form) {
        if (!lib.mutation.allowedForOrigin(req, lib.config.load().public_origin)) return .{ .status = .forbidden, .content_type = .text, .body = "cross-site mutation rejected" };
        if (req.body.len == 0 or req.body.len > 64 * 1024) return formRedirect(req, form.?.redirect_path, false);
    }
    const target = route(req.allocator, envelope) catch return if (form) |value| formRedirect(req, value.redirect_path, false) else mer.badRequest("unknown mutation action");
    if (!target[2] and (envelope.idempotency_key.len < 16 or !safeSegment(envelope.idempotency_key))) return if (form) |value| formRedirect(req, value.redirect_path, false) else mer.badRequest("invalid idempotency key");
    const body = if (form) |value| value.body else payloadJson(req.allocator, envelope.payload) catch return mer.badRequest("invalid mutation payload");
    const result = lib.backend.proxy(req.allocator, session.token, envelope.idempotency_key, target[0], target[1], body, if (target[2]) 10 * 1024 * 1024 else 2 * 1024 * 1024);
    if (result.status == 0) return if (form) |value| formRedirect(req, value.redirect_path, false) else .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"backend unavailable\"}" };
    if (result.status == 401) {
        const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("session clear failed");
        cookies[0] = lib.session.clearCookie();
        const response: mer.Response = if (form != null) mer.redirect("/login?reason=session_expired", .see_other) else .{ .status = .unauthorized, .content_type = .json, .body = "{\"error\":\"session expired\"}" };
        return mer.withCookies(response, cookies);
    }
    if (form) |value| return formRedirect(req, value.redirect_path, result.status >= 200 and result.status < 300);
    var response = mer.Response{ .status = @enumFromInt(result.status), .content_type = .json, .body = result.body };
    if (target[2] and result.status >= 200 and result.status < 300) {
        const is_page = std.mem.eql(u8, envelope.action, "page.download");
        const expected_type = if (is_page) "text/markdown" else "application/zip";
        if (!std.ascii.eqlIgnoreCase(mediaType(result.content_type), expected_type)) return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"invalid export content type\"}" };
        const disposition = canonicalDisposition(req.allocator, result.content_disposition) orelse return .{ .status = .bad_gateway, .content_type = .json, .body = "{\"error\":\"invalid export filename\"}" };
        const headers = req.allocator.alloc(std.http.Header, 2) catch return mer.internalError("download headers failed");
        headers[0] = .{ .name = "content-disposition", .value = disposition };
        headers[1] = .{ .name = "x-content-type-options", .value = "nosniff" };
        response.content_type = if (is_page) .markdown else .zip;
        response.headers = headers;
    }
    return response;
}

test "M3 proxy allowlist rejects arbitrary paths" {
    try std.testing.expectError(error.InvalidRoute, route(std.testing.allocator, .{ .action = "fetch", .idempotency_key = "12345678-1234-1234-1234-123456789012", .id = "https://evil.example" }));
}

test "form fallback builds the canonical study-output payload" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var req = mer.Request.init(arena.allocator(), .POST, "/api/m3");
    req.body = "action=output.create&output_type=study_guide&scope_type=topic&topic=recursion&title=Revision+guide";
    const mutation = try formMutation(req);
    try std.testing.expectEqualStrings("output.create", mutation.envelope.action);
    try std.testing.expectEqualStrings("/wiki/guides", mutation.redirect_path);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), mutation.body.?, .{});
    try std.testing.expectEqualStrings("study_guide", parsed.value.object.get("output_type").?.string);
    try std.testing.expectEqualStrings("recursion", parsed.value.object.get("topic").?.string);
    try std.testing.expectEqualStrings("Revision guide", parsed.value.object.get("title").?.string);
}

test "form fallback retains paper deletion and review fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var req = mer.Request.init(arena.allocator(), .POST, "/api/m3");
    req.body = "action=paper.updateQuestion&id=paper-1&child_id=question-1&question_text=Explain+recursion&topic_tag=recursion&confidence=0.75&reviewed=on";
    const mutation = try formMutation(req);
    try std.testing.expectEqualStrings("/sources/papers/paper-1", mutation.redirect_path);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), mutation.body.?, .{});
    try std.testing.expect(parsed.value.object.get("reviewed").?.bool);
    try std.testing.expect(parsed.value.object.get("awarded_marks").? == .null);
    try std.testing.expect(parsed.value.object.get("available_marks").? == .null);
}
