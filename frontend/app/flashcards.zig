// app/flashcards.zig — Milestone 2 flashcard practice prototype.
//
// Provides a deck overview plus a simple review queue backed by generated
// flashcard fixtures. The UI is server-rendered so it works before review APIs
// and persistence are wired up.

const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Flashcards",
    .description = "Practice generated flashcards from your workspace wiki pages.",
};

pub fn render(req: mer.Request) mer.Response {
    const selected_deck_id = req.queryParam("deck") orelse firstDeckId();
    const selected_deck = findDeck(selected_deck_id) orelse lib.mock.decks[0];
    const now_secs = lib.time.nowSecs();

    var due_total: usize = 0;
    for (lib.mock.decks) |deck| due_total += deck.due_count;

    var selected_cards: usize = 0;
    for (lib.mock.flashcards) |card| {
        if (std.mem.eql(u8, card.deck_id, selected_deck.id)) selected_cards += 1;
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
        \\    <a class="cp-btn cp-btn-ghost" href="/wiki/immutable-lists">Open wiki</a>
        \\    <a class="cp-btn cp-btn-primary" href="/chat">Ask follow-up</a>
        \\  </div>
        \\</header>
    ) catch return mer.internalError("flashcards render failed");

    w.writeAll("<section class=\"cp-metric-grid\">\n") catch return mer.internalError("flashcards render failed");
    metricCard(w, "Due now", due_total, "scheduled review") catch return mer.internalError("flashcards render failed");
    metricCard(w, "Decks", lib.mock.decks.len, "generated sets") catch return mer.internalError("flashcards render failed");
    metricCard(w, "Cards", lib.mock.flashcards.len, "source-backed prompts") catch return mer.internalError("flashcards render failed");
    metricCard(w, "Selected", selected_cards, "in this queue") catch return mer.internalError("flashcards render failed");
    w.writeAll("</section>\n") catch return mer.internalError("flashcards render failed");

    w.writeAll(
        \\<div class="cp-study-layout">
        \\  <aside class="cp-card">
        \\    <div class="cp-card-title"><span>Decks</span><span>prototype</span></div>
        \\    <div class="cp-deck-list">
    ) catch return mer.internalError("flashcards render failed");

    for (lib.mock.decks) |deck| {
        renderDeckLink(req, w, deck, selected_deck.id, now_secs) catch return mer.internalError("flashcards render failed");
    }

    const safe_title = lib.ui.escape(req.allocator, selected_deck.title) catch selected_deck.title;
    const safe_desc = lib.ui.escape(req.allocator, selected_deck.description) catch selected_deck.description;

    w.print(
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
    , .{ selected_cards, safe_title, safe_desc, selected_deck.due_count, selected_deck.card_count }) catch return mer.internalError("flashcards render failed");

    var rendered_cards: usize = 0;
    for (lib.mock.flashcards) |card| {
        if (!std.mem.eql(u8, card.deck_id, selected_deck.id)) continue;
        rendered_cards += 1;
        renderFlashcard(req, w, card, rendered_cards) catch return mer.internalError("flashcards render failed");
    }

    if (rendered_cards == 0) {
        w.writeAll("      <div class=\"cp-empty\">This deck does not have generated cards yet.</div>\n") catch return mer.internalError("flashcards render failed");
    }

    w.writeAll(
        \\    </div>
        \\  </section>
        \\</div>
    ) catch return mer.internalError("flashcards render failed");

    return lib.ui.htmlResponse(&buf);
}

fn firstDeckId() []const u8 {
    if (lib.mock.decks.len == 0) return "";
    return lib.mock.decks[0].id;
}

fn findDeck(id: []const u8) ?lib.types.FlashcardDeck {
    for (lib.mock.decks) |deck| {
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

fn renderDeckLink(
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

fn renderFlashcard(req: mer.Request, w: *std.Io.Writer, card: lib.types.Flashcard, index: usize) !void {
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
        \\          <button class="cp-btn cp-btn-ghost" type="button">Again</button>
        \\          <button class="cp-btn cp-btn-ghost" type="button">Good</button>
        \\          <button class="cp-btn cp-btn-primary" type="button">Easy</button>
        \\        </div>
        \\      </article>
    , .{ index, safe_topic, safe_question, safe_answer, card.citation.url, safe_citation_title, safe_snippet });
}
