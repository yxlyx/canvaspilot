const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

fn safeId(raw: []const u8) ?[]const u8 {
    if (raw.len == 0 or raw.len > 128) return null;
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return null,
        }
    }
    return raw;
}

fn parseCorrect(raw: ?[]const u8) ?bool {
    const value = raw orelse return null;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn parseConfidence(raw: ?[]const u8) ?u8 {
    const value = raw orelse return null;
    if (value.len != 1 or value[0] < '1' or value[0] > '5') return null;
    return value[0] - '0';
}

fn redirect(allocator: std.mem.Allocator, deck_id: ?[]const u8, status: []const u8) mer.Response {
    const deck = if (deck_id) |raw| safeId(raw) else null;
    if (deck == null) return mer.redirect("/flashcards?attempt=failed", .see_other);
    const target = std.fmt.allocPrint(
        allocator,
        "/flashcards?deck={s}&attempt={s}",
        .{ deck.?, status },
    ) catch "/flashcards?attempt=failed";
    return mer.redirect(target, .see_other);
}

pub fn render(req: mer.Request) mer.Response {
    if (req.method != .POST) {
        return .{ .status = .method_not_allowed, .content_type = .text, .body = "POST only" };
    }
    if (lib.m3.isExplicitDemo(req)) {
        return mer.badRequest("flashcard attempts are unavailable in demo mode");
    }
    if (!lib.mutation.allowedForOrigin(req, lib.config.load().public_origin)) {
        return .{ .status = .forbidden, .content_type = .text, .body = "cross-site flashcard attempt rejected" };
    }

    const session = lib.session.fromRequest(req);
    const card_id = lib.form.value(req.allocator, req.body, "card_id") catch null;
    const deck_id = lib.form.value(req.allocator, req.body, "deck_id") catch null;
    const correct_raw = lib.form.value(req.allocator, req.body, "correct") catch null;
    const confidence_raw = lib.form.value(req.allocator, req.body, "confidence") catch null;

    if (!session.isAuthenticated()) {
        return redirect(req.allocator, deck_id, "failed");
    }
    if (card_id == null) {
        return redirect(req.allocator, deck_id, "failed");
    }
    // Validate card_id before it is interpolated into the backend request path.
    if (safeId(card_id.?) == null) {
        return redirect(req.allocator, deck_id, "failed");
    }
    const is_correct = parseCorrect(correct_raw) orelse return redirect(req.allocator, deck_id, "failed");
    const confidence = parseConfidence(confidence_raw) orelse return redirect(req.allocator, deck_id, "failed");

    const result = lib.backend.submitFlashcardAttempt(
        req.allocator,
        session.token,
        card_id.?,
        is_correct,
        confidence,
    );
    if (result.value != null) return redirect(req.allocator, deck_id, "saved");
    return redirect(req.allocator, deck_id, "failed");
}

test "flashcard attempt fields accept only exact supported values" {
    try std.testing.expectEqual(true, parseCorrect("true").?);
    try std.testing.expectEqual(false, parseCorrect("false").?);
    try std.testing.expect(parseCorrect(null) == null);
    try std.testing.expect(parseCorrect("True") == null);
    try std.testing.expect(parseCorrect("true ") == null);
    try std.testing.expect(parseCorrect("1") == null);

    inline for (1..6) |value| {
        const raw = [_]u8{'0' + value};
        try std.testing.expectEqual(@as(u8, value), parseConfidence(&raw).?);
    }
    try std.testing.expect(parseConfidence(null) == null);
    try std.testing.expect(parseConfidence("0") == null);
    try std.testing.expect(parseConfidence("6") == null);
    try std.testing.expect(parseConfidence("01") == null);
    try std.testing.expect(parseConfidence("3 ") == null);
}

test "flashcard attempts reject cross-site requests before backend access" {
    var req = mer.Request.init(std.testing.allocator, .POST, "/api/flashcards/attempt");
    req.headers = &.{
        .{ .name = "Origin", .value = "https://cross-site.invalid" },
        .{ .name = "Sec-Fetch-Site", .value = "cross-site" },
    };
    try std.testing.expectEqual(std.http.Status.forbidden, render(req).status);

    req.headers = &.{};
    try std.testing.expectEqual(std.http.Status.forbidden, render(req).status);
}
