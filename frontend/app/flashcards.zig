// app/flashcards.zig — Milestone 2 flashcard practice prototype.
//
// Provides a deck overview plus a simple review queue. Live sessions use
// backend flashcard decks; fixtures are available only in explicit demo mode.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Flashcards",
    .description = "Practice generated flashcards from your workspace wiki pages.",
};

const Rating = struct {
    label: []const u8,
    correct: bool,
    confidence: u8,
    class_name: []const u8,
};

const ratings = [_]Rating{
    .{ .label = "Again", .correct = false, .confidence = 1, .class_name = "cp-btn cp-btn-ghost" },
    .{ .label = "Hard", .correct = true, .confidence = 2, .class_name = "cp-btn cp-btn-ghost" },
    .{ .label = "Good", .correct = true, .confidence = 3, .class_name = "cp-btn cp-btn-ghost" },
    .{ .label = "Easy", .correct = true, .confidence = 5, .class_name = "cp-btn cp-btn-primary" },
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const use_mock = lib.m3.isExplicitDemo(req);
    const selected_deck_id = req.queryParam("deck") orelse "";
    const now_secs = lib.time.nowSecs();

    var live_decks: ?[]const lib.types.FlashcardDeckResponse = null;
    if (!use_mock) {
        const result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (result.value) |parsed_decks| {
            live_decks = parsed_decks.value;
        } else {
            return lib.m3.liveError(req, "Flashcards", result.status);
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoBanner(req, w) catch return mer.internalError("flashcards render failed");
    const wiki_href = lib.m3.demoHref(req.allocator, req, "/wiki") catch return mer.internalError("flashcards render failed");
    const chat_href = lib.m3.demoHref(req.allocator, req, "/chat") catch return mer.internalError("flashcards render failed");

    w.print(
        \\<header class="cp-page-header cp-flashcard-header">
        \\  <div>
        \\    <h1 class="cp-page-title">Flashcards</h1>
        \\    <div class="cp-page-sub">Practice generated cards with source-backed answers and citations.</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="{s}">Open wiki</a>
        \\    <a class="cp-btn cp-btn-primary" href="{s}">Ask follow-up</a>
        \\  </div>
        \\</header>
    , .{ wiki_href, chat_href }) catch return mer.internalError("flashcards render failed");

    if (req.queryParam("attempt")) |attempt| {
        if (std.mem.eql(u8, attempt, "saved")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Practice result saved to learning evidence.</div>\n") catch return mer.internalError("flashcards render failed");
        } else if (std.mem.eql(u8, attempt, "failed")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-error\">Practice result could not be saved. Your answer was not recorded; try again.</div>\n") catch return mer.internalError("flashcards render failed");
        }
    }
    if (live_decks) |decks| {
        if (decks.len == 0) {
            renderMetrics(w, 0, 0, 0) catch return mer.internalError("flashcards render failed");
            w.writeAll("<section class=\"cp-card\"><div class=\"cp-empty\">No flashcard decks have been generated yet.</div></section>") catch return mer.internalError("flashcards render failed");
            return lib.ui.htmlResponse(&buf);
        }
        return renderLiveDecks(req, w, &buf, decks, selected_deck_id, now_secs);
    }
    return renderMockDecks(req, w, &buf, selected_deck_id, now_secs);
}

fn renderLiveDecks(
    req: mer.Request,
    w: *std.Io.Writer,
    buf: *std.Io.Writer.Allocating,
    decks: []const lib.types.FlashcardDeckResponse,
    selected_deck_id: []const u8,
    now_secs: i64,
) mer.Response {
    var card_total: usize = 0;
    for (decks) |deck| card_total += deck.card_count;
    const selected_deck = findLiveDeck(decks, selected_deck_id) orelse decks[0];

    renderMetrics(w, decks.len, card_total, selected_deck.cards.len) catch return mer.internalError("flashcards render failed");
    renderLayoutStart(w) catch return mer.internalError("flashcards render failed");
    for (decks) |deck| {
        renderLiveDeckLink(req, w, deck, selected_deck.id, now_secs) catch return mer.internalError("flashcards render failed");
    }

    const safe_title = lib.ui.escapeSafe(req.allocator, selected_deck.title);
    const safe_desc = lib.ui.escapeSafe(req.allocator, selected_deck.description);
    renderQueueHeader(w, selected_deck.cards.len, safe_title, safe_desc, selected_deck.card_count) catch return mer.internalError("flashcards render failed");

    if (selected_deck.cards.len == 0) {
        w.writeAll("      <div class=\"cp-empty\">This deck does not have generated cards yet.</div>\n") catch return mer.internalError("flashcards render failed");
    }
    for (selected_deck.cards, 0..) |card, index| {
        renderLiveFlashcard(req, w, selected_deck.id, card, index + 1) catch return mer.internalError("flashcards render failed");
    }
    renderLayoutEnd(w) catch return mer.internalError("flashcards render failed");
    return lib.ui.htmlResponse(buf);
}

fn renderMockDecks(
    req: mer.Request,
    w: *std.Io.Writer,
    buf: *std.Io.Writer.Allocating,
    selected_deck_id: []const u8,
    now_secs: i64,
) mer.Response {
    const selected_id = if (selected_deck_id.len > 0) selected_deck_id else firstMockDeckId();
    const selected_deck = if (selected_deck_id.len > 0)
        (findMockDeck(selected_id) orelse null)
    else
        (findMockDeck(selected_id) orelse lib.mock.decks[0]);

    if (selected_deck == null) {
        renderMetrics(w, lib.mock.decks.len, lib.mock.flashcards.len, 0) catch return mer.internalError("flashcards render failed");
        renderLayoutStart(w) catch return mer.internalError("flashcards render failed");
        for (lib.mock.decks) |d| {
            renderMockDeckLink(req, w, d, "", now_secs) catch return mer.internalError("flashcards render failed");
        }
        renderQueueHeader(w, 0, "Deck not found", "No deck matches that id.", 0) catch return mer.internalError("flashcards render failed");
        w.writeAll("      <div class=\"cp-empty\">No deck matches the requested id. Pick one from the list.</div>\n") catch return mer.internalError("flashcards render failed");
        renderLayoutEnd(w) catch return mer.internalError("flashcards render failed");
        return lib.ui.htmlResponse(buf);
    }
    const deck = selected_deck.?;

    var selected_cards: usize = 0;
    for (lib.mock.flashcards) |card| {
        if (std.mem.eql(u8, card.deck_id, deck.id)) selected_cards += 1;
    }

    renderMetrics(w, lib.mock.decks.len, lib.mock.flashcards.len, selected_cards) catch return mer.internalError("flashcards render failed");
    renderLayoutStart(w) catch return mer.internalError("flashcards render failed");
    for (lib.mock.decks) |d| {
        renderMockDeckLink(req, w, d, deck.id, now_secs) catch return mer.internalError("flashcards render failed");
    }

    const safe_title = lib.ui.escapeSafe(req.allocator, deck.title);
    const safe_desc = lib.ui.escapeSafe(req.allocator, deck.description);
    renderQueueHeader(w, selected_cards, safe_title, safe_desc, deck.card_count) catch return mer.internalError("flashcards render failed");

    var rendered_cards: usize = 0;
    for (lib.mock.flashcards) |card| {
        if (!std.mem.eql(u8, card.deck_id, deck.id)) continue;
        rendered_cards += 1;
        renderMockFlashcard(req, w, card, rendered_cards) catch return mer.internalError("flashcards render failed");
    }

    if (rendered_cards == 0) {
        w.writeAll("      <div class=\"cp-empty\">This deck does not have generated cards yet.</div>\n") catch return mer.internalError("flashcards render failed");
    }
    renderLayoutEnd(w) catch return mer.internalError("flashcards render failed");
    return lib.ui.htmlResponse(buf);
}

fn renderMetrics(w: *std.Io.Writer, deck_total: usize, card_total: usize, selected_cards: usize) !void {
    try w.writeAll("<section class=\"cp-metric-grid cp-flashcard-metrics\">\n");
    try metricCard(w, "Decks", deck_total, "generated sets");
    try metricCard(w, "Cards", card_total, "source-backed prompts");
    try metricCard(w, "Selected", selected_cards, "in this deck");
    try w.writeAll("</section>\n");
}

fn renderLayoutStart(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<div class="cp-study-layout">
        \\  <aside class="cp-card cp-deck-panel">
        \\    <div class="cp-card-title"><span>Decks</span><span>metadata</span></div>
        \\    <div class="cp-deck-list">
    );
}

fn renderQueueHeader(
    w: *std.Io.Writer,
    selected_cards: usize,
    title: []const u8,
    desc: []const u8,
    card_count: usize,
) !void {
    try w.print(
        \\    </div>
        \\  </aside>
        \\  <section class="cp-card cp-practice-panel">
        \\    <div class="cp-card-title"><span>Practice queue</span><span>{d} cards</span></div>
        \\    <div class="cp-practice-intro">
        \\      <div>
        \\        <h2>{s}</h2>
        \\        <p>{s}</p>
        \\      </div>
        \\      <div class="cp-score-panel">
        \\        <strong>{d}</strong>
        \\        <small>cards in deck</small>
        \\      </div>
        \\    </div>
        \\    <div class="cp-flashcard-list">
    , .{ selected_cards, title, desc, card_count });
}

fn renderLayoutEnd(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\    </div>
        \\  </section>
        \\</div>
    );
}

fn firstMockDeckId() []const u8 {
    if (lib.mock.decks.len == 0) return "";
    return lib.mock.decks[0].id;
}

fn findMockDeck(id: []const u8) ?lib.types.FlashcardDeck {
    for (lib.mock.decks) |deck| {
        if (std.mem.eql(u8, deck.id, id)) return deck;
    }
    return null;
}

fn findLiveDeck(decks: []const lib.types.FlashcardDeckResponse, id: []const u8) ?lib.types.FlashcardDeckResponse {
    for (decks) |deck| {
        if (std.mem.eql(u8, deck.id, id)) return deck;
    }
    return null;
}

fn metricCard(w: *std.Io.Writer, label: []const u8, value: usize, helper: []const u8) !void {
    try w.print(
        \\  <div class="cp-metric-card cp-metric-static">
        \\    <span class="cp-metric-label">{s}</span>
        \\    <span class="cp-metric-value">{d}</span>
        \\    <span class="cp-metric-sub">{s}</span>
        \\  </div>
    , .{ label, value, helper });
}

fn safeToken(raw: []const u8, fallback: []const u8) []const u8 {
    if (raw.len == 0 or raw.len > 128) return fallback;
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
            else => return fallback,
        }
    }
    return raw;
}

fn renderLiveDeckLink(
    req: mer.Request,
    w: *std.Io.Writer,
    deck: lib.types.FlashcardDeckResponse,
    selected_id: []const u8,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, deck.title);
    const safe_desc = lib.ui.escapeSafe(req.allocator, deck.description);
    const safe_deck_id = lib.ui.escape(req.allocator, safeToken(deck.id, "")) catch "";
    const when = lib.time.formatRelative(req.allocator, deck.updated_at, now_secs) catch "—";
    const is_selected = std.mem.eql(u8, deck.id, selected_id);
    const cls: []const u8 = if (is_selected) "cp-deck-row cp-deck-row-active" else "cp-deck-row";
    const aria_current: []const u8 = if (is_selected) " aria-current=\"true\"" else "";

    try w.print(
        \\      <a class="{s}" href="/flashcards?deck={s}"{s}>
        \\        <span>{s}</span>
        \\        <small>{s}</small>
        \\        <em>{d} cards · updated {s}</em>
        \\      </a>
    , .{ cls, safe_deck_id, aria_current, safe_title, safe_desc, deck.card_count, when });
}

fn renderMockDeckLink(
    req: mer.Request,
    w: *std.Io.Writer,
    deck: lib.types.FlashcardDeck,
    selected_id: []const u8,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escapeSafe(req.allocator, deck.title);
    const safe_desc = lib.ui.escapeSafe(req.allocator, deck.description);
    const when = lib.time.formatRelative(req.allocator, deck.updated_at, now_secs) catch "—";
    const is_selected = std.mem.eql(u8, deck.id, selected_id);
    const cls: []const u8 = if (is_selected) "cp-deck-row cp-deck-row-active" else "cp-deck-row";
    const aria_current: []const u8 = if (is_selected) " aria-current=\"true\"" else "";
    const path = try std.fmt.allocPrint(req.allocator, "/flashcards?deck={s}", .{deck.id});
    const href = try lib.m3.demoHref(req.allocator, req, path);

    try w.print(
        \\      <a class="{s}" href="{s}"{s}>
        \\        <span>{s}</span>
        \\        <small>{s}</small>
        \\        <em>{d} cards · updated {s}</em>
        \\      </a>
    , .{ cls, href, aria_current, safe_title, safe_desc, deck.card_count, when });
}

fn renderLiveFlashcard(
    req: mer.Request,
    w: *std.Io.Writer,
    deck_id: []const u8,
    card: lib.types.FlashcardResponse,
    index: usize,
) !void {
    const safe_question = lib.ui.escapeSafe(req.allocator, card.question);
    const safe_answer = lib.ui.escapeSafe(req.allocator, card.answer);
    const safe_topic = lib.ui.escapeSafe(req.allocator, card.topic_tag);
    const safe_source = lib.ui.escapeSafe(req.allocator, card.source_title);
    const safe_ref = lib.ui.escapeSafe(req.allocator, card.citation_ref);
    const safe_card_id = lib.ui.escape(req.allocator, safeToken(card.id, "")) catch "";
    const safe_deck_id = lib.ui.escape(req.allocator, safeToken(deck_id, "")) catch "";

    try w.print(
        \\      <article class="cp-flashcard">
        \\        <div class="cp-flashcard-top">
        \\          <span>Card {d}</span>
        \\          <span class="cp-topic-pill">{s}</span>
        \\        </div>
        \\        <h3>{s}</h3>
        \\        <details>
        \\          <summary>Reveal answer</summary>
        \\          <p>{s}</p>
        \\          <a class="cp-citation-card" href="/sources">
        \\            <span>{s}</span>
        \\            <small>{s}</small>
        \\          </a>
        \\          <div class="cp-review-actions" aria-label="Rate this answer">
    , .{ index, safe_topic, safe_question, safe_answer, safe_source, safe_ref });

    for (ratings) |rating| {
        try renderAttemptForm(req, w, safe_card_id, safe_deck_id, rating.correct, rating.confidence, rating.class_name, rating.label);
    }
    try w.writeAll(
        \\          </div>
        \\        </details>
        \\      </article>
    );
}

fn renderAttemptForm(
    req: mer.Request,
    w: *std.Io.Writer,
    card_id: []const u8,
    deck_id: []const u8,
    is_correct: bool,
    confidence: u8,
    class_name: []const u8,
    label: []const u8,
) !void {
    const correct_value: []const u8 = if (is_correct) "true" else "false";
    const safe_card_id = lib.ui.escape(req.allocator, safeToken(card_id, "")) catch "";
    const safe_deck_id = lib.ui.escape(req.allocator, safeToken(deck_id, "")) catch "";
    try w.print(
        \\          <form action="/api/flashcards/attempt" method="post">
        \\            <input type="hidden" name="card_id" value="{s}">
        \\            <input type="hidden" name="deck_id" value="{s}">
        \\            <input type="hidden" name="correct" value="{s}">
        \\            <input type="hidden" name="confidence" value="{d}">
        \\            <button class="{s}" type="submit">{s}</button>
        \\          </form>
    , .{ safe_card_id, safe_deck_id, correct_value, confidence, class_name, label });
}

fn renderMockFlashcard(
    req: mer.Request,
    w: *std.Io.Writer,
    card: lib.types.Flashcard,
    index: usize,
) !void {
    const safe_question = lib.ui.escapeSafe(req.allocator, card.question);
    const safe_answer = lib.ui.escapeSafe(req.allocator, card.answer);
    const safe_topic = lib.ui.escapeSafe(req.allocator, card.topic);
    const safe_citation_title = lib.ui.escapeSafe(req.allocator, card.citation.title);
    const safe_snippet = lib.ui.escapeSafe(req.allocator, card.citation.snippet);
    const citation_href = if (std.mem.startsWith(u8, card.citation.url, "/")) try lib.m3.demoHref(req.allocator, req, card.citation.url) else card.citation.url;

    try w.print(
        \\      <article class="cp-flashcard">
        \\        <div class="cp-flashcard-top">
        \\          <span>Card {d}</span>
        \\          <span class="cp-topic-pill">{s}</span>
        \\        </div>
        \\        <h3>{s}</h3>
        \\        <details>
        \\          <summary>Reveal answer</summary>
        \\          <p>{s}</p>
        \\          <a class="cp-citation-card" href="{s}">
        \\            <span>{s}</span>
        \\            <small>{s}</small>
        \\          </a>
        \\          <p class="cp-demo-rating-note" role="note">Demo preview: ratings are disabled and are not saved.</p>
        \\          <div class="cp-review-actions" aria-label="Demo ratings unavailable">
        \\            <button class="cp-btn cp-btn-ghost" type="button" disabled>Again</button>
        \\            <button class="cp-btn cp-btn-ghost" type="button" disabled>Hard</button>
        \\            <button class="cp-btn cp-btn-ghost" type="button" disabled>Good</button>
        \\            <button class="cp-btn cp-btn-primary" type="button" disabled>Easy</button>
        \\          </div>
        \\        </details>
        \\      </article>
    , .{ index, safe_topic, safe_question, safe_answer, citation_href, safe_citation_title, safe_snippet });
}

test "flashcard ratings use the supported confidence scale" {
    try std.testing.expectEqual(@as(usize, 4), ratings.len);
    try std.testing.expectEqualStrings("Again", ratings[0].label);
    try std.testing.expect(!ratings[0].correct);
    try std.testing.expectEqual(@as(u8, 1), ratings[0].confidence);
    try std.testing.expectEqualStrings("Hard", ratings[1].label);
    try std.testing.expectEqual(@as(u8, 2), ratings[1].confidence);
    try std.testing.expectEqualStrings("Good", ratings[2].label);
    try std.testing.expectEqual(@as(u8, 3), ratings[2].confidence);
    try std.testing.expectEqualStrings("Easy", ratings[3].label);
    try std.testing.expectEqual(@as(u8, 5), ratings[3].confidence);
}
