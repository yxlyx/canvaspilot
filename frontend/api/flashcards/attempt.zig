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

    const session = lib.session.fromRequest(req);
    const card_id = lib.form.value(req.allocator, req.body, "card_id") catch null;
    const deck_id = lib.form.value(req.allocator, req.body, "deck_id") catch null;
    const correct_raw = lib.form.value(req.allocator, req.body, "correct") catch null;
    const confidence_raw = lib.form.value(req.allocator, req.body, "confidence") catch null;

    if (!session.isAuthenticated()) {
        return redirect(req.allocator, deck_id, "failed");
    }
    if (card_id == null or correct_raw == null) {
        return redirect(req.allocator, deck_id, "failed");
    }
    // Validate card_id before it is interpolated into the backend request path.
    if (safeId(card_id.?) == null) {
        return redirect(req.allocator, deck_id, "failed");
    }

    const is_correct = std.mem.eql(u8, correct_raw.?, "true");
    const confidence: ?u8 = if (confidence_raw) |raw|
        std.fmt.parseInt(u8, raw, 10) catch null
    else
        null;

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
