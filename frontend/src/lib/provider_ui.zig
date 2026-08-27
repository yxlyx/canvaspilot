const std = @import("std");
const types = @import("types.zig");

pub const State = enum {
    active,
    unfinished,
    disconnected,
    unavailable,
};

pub fn classify(settings: []const types.ProviderStatusResponse) State {
    if (settings.len == 0) return .disconnected;
    for (settings) |setting| {
        if (setting.active_for_generation) return .active;
    }
    return .unfinished;
}

pub fn renderBoundary(w: anytype, state: State, context: []const u8) !void {
    if (state == .active) return;
    const copy = switch (state) {
        .unfinished => "Your provider is connected but still needs a model and successful test.",
        .disconnected => "Connect a provider to create cited answers and new study material.",
        .unavailable => "Provider status is temporarily unavailable. Reading and existing study material still work.",
        .active => unreachable,
    };
    const title = switch (state) {
        .unfinished => "Finish provider setup",
        .disconnected => "Connect an AI provider",
        .unavailable => "Provider status unavailable",
        .active => unreachable,
    };
    const tone = if (state == .unavailable) "neutral" else "attention";
    try w.print(
        "<aside class=\"cp-provider-boundary is-{s}\" data-provider-state=\"{s}\" role=\"status\"><span class=\"cp-provider-boundary-icon\" aria-hidden=\"true\"><svg viewBox=\"0 0 24 24\"><path d=\"M12 3v3M12 18v3M3 12h3M18 12h3\"/><circle cx=\"12\" cy=\"12\" r=\"4\"/></svg></span><div><strong>{s}</strong><p>{s} {s}</p></div><a class=\"cp-btn cp-btn-ghost\" href=\"/settings/providers\">Open provider settings</a></aside>",
        .{ tone, @tagName(state), title, context, copy },
    );
}

test "provider readiness prioritises the active generation setting" {
    const items = [_]types.ProviderStatusResponse{
        .{ .provider = "openai", .model = "one", .endpoint = "", .status = "connected", .last_tested_at = null, .updated_at = "" },
        .{ .provider = "codegraff", .model = "two", .endpoint = "", .status = "connected", .active_for_generation = true, .last_tested_at = null, .updated_at = "" },
    };
    try std.testing.expectEqual(State.active, classify(&items));
    try std.testing.expectEqual(State.disconnected, classify(&.{}));
}
