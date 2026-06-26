// app/flashcards.zig — Milestone 2 flashcard practice prototype.
//
// Provides a deck overview plus a simple review queue. Authenticated sessions
// use backend flashcard decks and fall back to fixtures for offline demos.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Flashcards",
    .description = "Practice generated flashcards from your workspace wiki pages.",
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    const selected_deck_id = req.queryParam("deck") orelse "";
    const now_secs = lib.time.nowSecs();

    var live_decks: ?[]const lib.types.FlashcardDeckResponse = null;
    var backend_message: ?[]const u8 = if (use_mock) "Showing prototype flashcard fixtures." else null;
    if (!use_mock) {
        const result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (result.value) |parsed_decks| {
            if (parsed_decks.value.len > 0) {
                live_decks = parsed_decks.value;
                backend_message = null;
            } else {
                backend_message = "No backend flashcard decks yet — showing prototype fixtures.";
            }
        } else {
            backend_message = "Backend flashcard metadata is unavailable — showing prototype fixtures.";
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    w.writeAll(
        \\<header class="cp-page-header">
        \\  <div>
        \\    <div class="cp-page-title">Flashcards</div>
        \\    <div class="cp-page-sub">Practice generated cards with source-backed answers and citations.</div>
        \\  </div>
        \\  <div class="cp-page-actions">
        \\    <a class="cp-btn cp-btn-ghost" href="/wiki">Open wiki</a>
        \\    <a class="cp-btn cp-btn-primary" href="/chat">Ask follow-up</a>
        \\  </div>
        \\</header>
    ) catch return mer.internalError("flashcards render failed");

    if (req.queryParam("attempt")) |attempt| {
        if (std.mem.eql(u8, attempt, "saved")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-info\">Practice result saved to learning evidence.</div>\n") catch return mer.internalError("flashcards render failed");
        } else if (std.mem.eql(u8, attempt, "failed")) {
            w.writeAll("<div class=\"cp-status-banner cp-status-error\">Practice result could not be saved. You can keep reviewing with local state.</div>\n") catch return mer.internalError("flashcards render failed");
        }
    }
    if (backend_message) |message| {
        const safe_message = lib.ui.escape(req.allocator, message) catch message;
        w.print("<div class=\"cp-status-banner cp-status-info\">{s}</div>\n", .{safe_message}) catch return mer.internalError("flashcards render failed");
    }

    if (live_decks) |decks| {
        return renderLiveDecks(req, w, &buf, decks, selected_deck_id, now_secs);
    }
    return renderMockDecks(req, w, &buf, selected_deck_id, now_secs, false);
}

fn renderLiveDecks(
    req: mer.Request,
    w: *std.Io.Writer,
    buf: *std.Io.Writer.Allocating,
    decks: []const lib.types.FlashcardDeckResponse,
    selected_deck_id: []const u8,
    now_secs: i64,
) mer.Response {
    var due_total: usize = 0;
    var card_total: usize = 0;
    for (decks) |deck| {
        due_total += deck.cards.len;
        card_total += deck.card_count;
    }
    const selected_deck = findLiveDeck(decks, selected_deck_id) orelse decks[0];

    renderMetrics(w, due_total, decks.len, card_total, selected_deck.cards.len) catch return mer.internalError("flashcards render failed");
    renderLayoutStart(w) catch return mer.internalError("flashcards render failed");
    for (decks) |deck| {
        renderLiveDeckLink(req, w, deck, selected_deck.id, now_secs) catch return mer.internalError("flashcards render failed");
    }

    const safe_title = lib.ui.escape(req.allocator, selected_deck.title) catch selected_deck.title;
    const safe_desc = lib.ui.escape(req.allocator, selected_deck.description) catch selected_deck.description;
    renderQueueHeader(w, selected_deck.cards.len, safe_title, safe_desc, selected_deck.cards.len, selected_deck.card_count) catch return mer.internalError("flashcards render failed");

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
    can_submit_attempts: bool,
) mer.Response {
    const selected_id = if (selected_deck_id.len > 0) selected_deck_id else firstMockDeckId();
    const selected_deck = findMockDeck(selected_id) orelse lib.mock.decks[0];

    var due_total: usize = 0;
    for (lib.mock.decks) |deck| due_total += deck.due_count;

    var selected_cards: usize = 0;
    for (lib.mock.flashcards) |card| {
        if (std.mem.eql(u8, card.deck_id, selected_deck.id)) selected_cards += 1;
    }

    renderMetrics(w, due_total, lib.mock.decks.len, lib.mock.flashcards.len, selected_cards) catch return mer.internalError("flashcards render failed");
    renderLayoutStart(w) catch return mer.internalError("flashcards render failed");
    for (lib.mock.decks) |deck| {
        renderMockDeckLink(req, w, deck, selected_deck.id, now_secs) catch return mer.internalError("flashcards render failed");
    }

    const safe_title = lib.ui.escape(req.allocator, selected_deck.title) catch selected_deck.title;
    const safe_desc = lib.ui.escape(req.allocator, selected_deck.description) catch selected_deck.description;
    renderQueueHeader(w, selected_cards, safe_title, safe_desc, selected_deck.due_count, selected_deck.card_count) catch return mer.internalError("flashcards render failed");

    var rendered_cards: usize = 0;
    for (lib.mock.flashcards) |card| {
        if (!std.mem.eql(u8, card.deck_id, selected_deck.id)) continue;
        rendered_cards += 1;
        renderMockFlashcard(req, w, selected_deck.id, card, rendered_cards, can_submit_attempts) catch return mer.internalError("flashcards render failed");
    }

    if (rendered_cards == 0) {
        w.writeAll("      <div class=\"cp-empty\">This deck does not have generated cards yet.</div>\n") catch return mer.internalError("flashcards render failed");
    }
    renderLayoutEnd(w) catch return mer.internalError("flashcards render failed");
    return lib.ui.htmlResponse(buf);
}

fn renderMetrics(w: *std.Io.Writer, due_total: usize, deck_total: usize, card_total: usize, selected_cards: usize) !void {
    try w.writeAll("<section class=\"cp-metric-grid\">\n");
    try metricCard(w, "Due now", due_total, "scheduled review");
    try metricCard(w, "Decks", deck_total, "generated sets");
    try metricCard(w, "Cards", card_total, "source-backed prompts");
    try metricCard(w, "Selected", selected_cards, "in this queue");
    try w.writeAll("</section>\n");
}

fn renderLayoutStart(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<div class="cp-study-layout">
        \\  <aside class="cp-card">
        \\    <div class="cp-card-title"><span>Decks</span><span>metadata</span></div>
        \\    <div class="cp-deck-list">
    );
}

fn renderQueueHeader(
    w: *std.Io.Writer,
    selected_cards: usize,
    title: []const u8,
    desc: []const u8,
    due_count: usize,
    card_count: usize,
) !void {
    try w.print(
        \\    </div>
        \\  </aside>
        \\  <section class="cp-card">
        \\    <div class="cp-card-title"><span>Practice queue</span><span>{d} cards</span></div>
        \\    <div class="cp-practice-intro">
        \\      <div>
        \\        <h2>{s}</h2>
        \\        <p>{s}</p>
        \\      </div>
        \\      <div class="cp-score-panel">
        \\        <strong>{d}</strong> due
        \\        <small>{d} total</small>
        \\      </div>
        \\    </div>
        \\    <div class="cp-flashcard-list">
    , .{ selected_cards, title, desc, due_count, card_count });
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
    const safe_title = lib.ui.escape(req.allocator, deck.title) catch deck.title;
    const safe_desc = lib.ui.escape(req.allocator, deck.description) catch deck.description;
    const safe_deck_id = lib.ui.escape(req.allocator, safeToken(deck.id, "")) catch "";
    const when = lib.time.formatRelative(req.allocator, deck.updated_at, now_secs) catch "—";
    const cls: []const u8 = if (std.mem.eql(u8, deck.id, selected_id)) "cp-deck-row cp-deck-row-active" else "cp-deck-row";

    try w.print(
        \\      <a class="{s}" href="/flashcards?deck={s}">
        \\        <span>{s}</span>
        \\        <small>{s}</small>
        \\        <em>{d} cards · updated {s}</em>
        \\      </a>
    , .{ cls, safe_deck_id, safe_title, safe_desc, deck.card_count, when });
}

fn renderMockDeckLink(
    req: mer.Request,
    w: *std.Io.Writer,
    deck: lib.types.FlashcardDeck,
    selected_id: []const u8,
    now_secs: i64,
) !void {
    const safe_title = lib.ui.escape(req.allocator, deck.title) catch deck.title;
    const safe_desc = lib.ui.escape(req.allocator, deck.description) catch deck.description;
    const when = lib.time.formatRelative(req.allocator, deck.updated_at, now_secs) catch "—";
    const cls: []const u8 = if (std.mem.eql(u8, deck.id, selected_id)) "cp-deck-row cp-deck-row-active" else "cp-deck-row";

    try w.print(
        \\      <a class="{s}" href="/flashcards?deck={s}">
        \\        <span>{s}</span>
        \\        <small>{s}</small>
        \\        <em>{d} due · updated {s}</em>
        \\      </a>
    , .{ cls, deck.id, safe_title, safe_desc, deck.due_count, when });
}

fn renderLiveFlashcard(
    req: mer.Request,
    w: *std.Io.Writer,
    deck_id: []const u8,
    card: lib.types.FlashcardResponse,
    index: usize,
) !void {
    const safe_question = lib.ui.escape(req.allocator, card.question) catch card.question;
    const safe_answer = lib.ui.escape(req.allocator, card.answer) catch card.answer;
    const safe_topic = lib.ui.escape(req.allocator, card.topic_tag) catch card.topic_tag;
    const safe_source = lib.ui.escape(req.allocator, card.source_title) catch card.source_title;
    const safe_ref = lib.ui.escape(req.allocator, card.citation_ref) catch card.citation_ref;
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
        \\        </details>
        \\        <div class="cp-review-actions">
        \\          <form action="/api/flashcards/attempt" method="post">
        \\            <input type="hidden" name="card_id" value="{s}">
        \\            <input type="hidden" name="deck_id" value="{s}">
        \\            <input type="hidden" name="correct" value="false">
        \\            <input type="hidden" name="confidence" value="1">
        \\            <button class="cp-btn cp-btn-ghost" type="submit">Again</button>
        \\          </form>
        \\          <form action="/api/flashcards/attempt" method="post">
        \\            <input type="hidden" name="card_id" value="{s}">
        \\            <input type="hidden" name="deck_id" value="{s}">
        \\            <input type="hidden" name="correct" value="true">
        \\            <input type="hidden" name="confidence" value="3">
        \\            <button class="cp-btn cp-btn-ghost" type="submit">Good</button>
        \\          </form>
        \\          <form action="/api/flashcards/attempt" method="post">
        \\            <input type="hidden" name="card_id" value="{s}">
        \\            <input type="hidden" name="deck_id" value="{s}">
        \\            <input type="hidden" name="correct" value="true">
        \\            <input type="hidden" name="confidence" value="5">
        \\            <button class="cp-btn cp-btn-primary" type="submit">Easy</button>
        \\          </form>
        \\        </div>
        \\      </article>
    , .{ index, safe_topic, safe_question, safe_answer, safe_source, safe_ref, safe_card_id, safe_deck_id, safe_card_id, safe_deck_id, safe_card_id, safe_deck_id });
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
    deck_id: []const u8,
    card: lib.types.Flashcard,
    index: usize,
    can_submit_attempts: bool,
) !void {
    const safe_question = lib.ui.escape(req.allocator, card.question) catch card.question;
    const safe_answer = lib.ui.escape(req.allocator, card.answer) catch card.answer;
    const safe_topic = lib.ui.escape(req.allocator, card.topic) catch card.topic;
    const safe_citation_title = lib.ui.escape(req.allocator, card.citation.title) catch card.citation.title;
    const safe_snippet = lib.ui.escape(req.allocator, card.citation.snippet) catch card.citation.snippet;

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
        \\        </details>
        \\        <div class="cp-review-actions">
    , .{ index, safe_topic, safe_question, safe_answer, card.citation.url, safe_citation_title, safe_snippet });

    if (can_submit_attempts) {
        try renderAttemptForm(req, w, card.id, deck_id, false, 1, "cp-btn cp-btn-ghost", "Again");
        try renderAttemptForm(req, w, card.id, deck_id, true, 3, "cp-btn cp-btn-ghost", "Good");
        try renderAttemptForm(req, w, card.id, deck_id, true, 5, "cp-btn cp-btn-primary", "Easy");
    } else {
        try w.writeAll(
            \\          <button class="cp-btn cp-btn-ghost" type="button">Again</button>
            \\          <button class="cp-btn cp-btn-ghost" type="button">Good</button>
            \\          <button class="cp-btn cp-btn-primary" type="button">Easy</button>
        );
    }

    try w.writeAll(
        \\        </div>
        \\      </article>
    );
}
