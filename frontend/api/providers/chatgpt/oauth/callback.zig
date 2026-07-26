const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

const CallbackRequest = struct {
    state: []const u8,
    code: ?[]const u8,
    @"error": ?[]const u8,
    browser_binding: []const u8,
};
const CallbackResponse = struct { return_path: []const u8 };

fn stateSessionId(state: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, state, '.') orelse return null;
    const value = state[0..end];
    if (value.len != 36) return null;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f', 'A'...'F', '-' => {},
        else => return null,
    };
    return value;
}

fn terminalRedirect(req: mer.Request, path: []const u8, session_id: []const u8) mer.Response {
    const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("provider callback failed");
    cookies[0] = lib.session.clearProviderAuthCookie(req.allocator, session_id) catch return mer.internalError("provider callback failed");
    return mer.withCookies(mer.redirect(path, .see_other), cookies);
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .GET) return .{ .status = .method_not_allowed, .content_type = .text, .body = "GET only" };
    const state = req.queryParam("state") orelse return mer.redirect("/settings/providers?provider=chatgpt&auth=failed", .see_other);
    const session_id = stateSessionId(state) orelse return mer.redirect("/settings/providers?provider=chatgpt&auth=failed", .see_other);
    const session = lib.session.fromRequest(req);
    if (!session.isAuthenticated()) return terminalRedirect(req, "/login?reason=session_expired", session_id);
    const cookie_name = std.fmt.allocPrint(req.allocator, "cp_provider_auth_{s}", .{session_id}) catch return mer.internalError("provider callback failed");
    const browser_binding = req.cookie(cookie_name) orelse return terminalRedirect(req, "/settings/providers?provider=chatgpt&auth=failed", session_id);
    if (state.len > 500 or browser_binding.len < 32 or browser_binding.len > 200) return terminalRedirect(req, "/settings/providers?provider=chatgpt&auth=failed", session_id);
    const code = req.queryParam("code");
    const provider_error = req.queryParam("error");
    if ((code == null and provider_error == null) or (code != null and code.?.len > 4096) or (provider_error != null and provider_error.?.len > 200)) return terminalRedirect(req, "/settings/providers?provider=chatgpt&auth=failed", session_id);

    var out: std.Io.Writer.Allocating = .init(req.allocator);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    stringify.write(CallbackRequest{
        .state = state,
        .code = code,
        .@"error" = provider_error,
        .browser_binding = browser_binding,
    }) catch return terminalRedirect(req, "/settings/providers?provider=chatgpt&auth=failed", session_id);
    const result = lib.backend.proxy(
        req.allocator,
        session.token,
        "",
        .POST,
        "/api/providers/chatgpt/oauth/callback",
        out.written(),
        16 * 1024,
    );
    const cookies = req.allocator.alloc(mer.SetCookie, 1) catch return mer.internalError("provider callback failed");
    cookies[0] = lib.session.clearProviderAuthCookie(req.allocator, session_id) catch return mer.internalError("provider callback failed");
    if (result.status == 401) return mer.withCookies(mer.redirect("/login?reason=session_expired", .see_other), cookies);
    if (result.status < 200 or result.status >= 300) return mer.withCookies(mer.redirect("/settings/providers?provider=chatgpt&auth=failed", .see_other), cookies);
    const parsed = std.json.parseFromSlice(CallbackResponse, req.allocator, result.body, .{ .ignore_unknown_fields = false }) catch return mer.withCookies(mer.redirect("/settings/providers?provider=chatgpt&auth=failed", .see_other), cookies);
    const target = lib.m3.safeInternalHref(parsed.value.return_path, "/settings/providers?provider=chatgpt&auth=failed");
    return mer.withCookies(mer.redirect(target, .see_other), cookies);
}
