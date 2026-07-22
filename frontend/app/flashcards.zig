const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{
    .title = "Flashcards",
    .description = "Review source-backed flashcards and record learning evidence.",
};

const ICON_LAYERS = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"m12 2 9 5-9 5-9-5 9-5Z\"/><path d=\"m3 12 9 5 9-5M3 17l9 5 9-5\"/></svg>";
const ICON_ARROW = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M5 12h14M13 6l6 6-6 6\"/></svg>";
const ICON_KEYBOARD = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><rect width=\"20\" height=\"16\" x=\"2\" y=\"4\" rx=\"2\"/><path d=\"M6 8h.01M10 8h.01M14 8h.01M18 8h.01M8 12h.01M12 12h.01M16 12h.01M7 16h10\"/></svg>";

const FixtureDeck = struct { id: []const u8, title: []const u8, module: []const u8, due: usize, total: usize };
const FixtureCard = struct { id: []const u8, deck_id: []const u8, question: []const u8, answer: []const u8, source: []const u8, page: []const u8 };

const fixture_decks = [_]FixtureDeck{
    .{ .id = "trees", .title = "Balanced trees", .module = "CS2040S", .due = 8, .total = 24 },
    .{ .id = "graphs", .title = "Graph traversal", .module = "CS2040S", .due = 5, .total = 18 },
    .{ .id = "quality", .title = "Project quality", .module = "CS2103T", .due = 3, .total = 15 },
};

const fixture_cards = [_]FixtureCard{
    .{ .id = "tree-1", .deck_id = "trees", .question = "What invariant makes an AVL tree balanced?", .answer = "For every node, the heights of its left and right subtrees differ by at most one. After an insertion or deletion, rotations restore this invariant on the affected path.", .source = "Lecture 08 — Balanced Search Trees", .page = "p. 12" },
    .{ .id = "tree-2", .deck_id = "trees", .question = "When is a double rotation required?", .answer = "A double rotation is used when the heavy child leans in the opposite direction from the unbalanced node: left-right or right-left. The child rotates first, then the node.", .source = "Lecture 08 — Balanced Search Trees", .page = "p. 18" },
    .{ .id = "tree-3", .deck_id = "trees", .question = "Why does AVL height remain logarithmic?", .answer = "The smallest AVL tree of a given height follows a Fibonacci-like recurrence, so node count grows exponentially with height. Therefore height grows logarithmically with node count.", .source = "Tutorial 05 — Graph Traversal", .page = "note 3" },
    .{ .id = "graph-1", .deck_id = "graphs", .question = "How does breadth-first search choose its next vertex?", .answer = "Breadth-first search uses a queue, visiting all vertices at the current distance before moving to the next layer.", .source = "Tutorial 05 — Graph Traversal", .page = "p. 4" },
    .{ .id = "quality-1", .deck_id = "quality", .question = "What makes a project decision reviewable?", .answer = "The decision records its context, considered trade-offs, owner, and a testable definition of done.", .source = "Project Team Guide", .page = "Decision log" },
};

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    const use_mock = req.queryParam("mock") != null or !session.isAuthenticated();
    const selected_id = req.queryParam("deck") orelse "";
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;

    if (!session.isAuthenticated()) {
        w.writeAll("<span hidden data-cp-auth=\"anonymous\"></span>\n") catch return mer.internalError("flashcards render failed");
    }

    w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">16 cards due</p><h1 class=\"cp-page-title\">Evidence-backed review</h1></div></header>\n") catch return mer.internalError("flashcards render failed");

    if (use_mock) {
        renderFixturePage(req, w, selected_id, session.isAuthenticated()) catch return mer.internalError("flashcards render failed");
        return lib.ui.htmlResponse(&buf);
    }

    const result = lib.backend.listFlashcardDecks(req.allocator, session.token);
    if (result.value) |parsed| {
        if (parsed.value.len > 0) {
            renderLivePage(req, w, parsed.value, selected_id) catch return mer.internalError("flashcards render failed");
            return lib.ui.htmlResponse(&buf);
        }
    }

    renderFixturePage(req, w, selected_id, session.isAuthenticated()) catch return mer.internalError("flashcards render failed");
    return lib.ui.htmlResponse(&buf);
}

fn renderFixturePage(req: mer.Request, w: *std.Io.Writer, selected_id: []const u8, can_submit: bool) !void {
    const active = findFixtureDeck(selected_id) orelse fixture_decks[0];
    try renderPageStart(w);
    for (fixture_decks) |deck| try renderDeckButton(req, w, deck.id, deck.title, deck.module, deck.total, deck.due, std.mem.eql(u8, deck.id, active.id));
    try renderDeckFooter(w);
    try renderReviewStart(req, w, active.module, active.title, active.due);

    var first: ?FixtureCard = null;
    for (fixture_cards) |card| if (std.mem.eql(u8, card.deck_id, active.id)) {
        first = card;
        break;
    };
    if (first) |card| {
        try renderCardShell(req, w, card.question, card.answer, card.source, card.page, card.id, active.id, can_submit);
        for (fixture_cards) |item| {
            if (!std.mem.eql(u8, item.deck_id, active.id)) continue;
            try renderCardData(req, w, item.id, item.question, item.answer, item.source, item.page);
        }
    } else {
        try w.writeAll("<div class=\"flash-empty surface\">This deck does not have generated cards yet.</div>");
    }
    try renderPageEnd(w, 5);
}

fn renderLivePage(req: mer.Request, w: *std.Io.Writer, decks: []const lib.types.FlashcardDeckResponse, selected_id: []const u8) !void {
    const active = findLiveDeck(decks, selected_id) orelse decks[0];
    try renderPageStart(w);
    for (decks) |deck| {
        const module = if (deck.topic_tags.len > 0) deck.topic_tags[0] else "Workspace";
        try renderDeckButton(req, w, deck.id, deck.title, module, deck.card_count, deck.cards.len, std.mem.eql(u8, deck.id, active.id));
    }
    try renderDeckFooter(w);
    const module = if (active.topic_tags.len > 0) active.topic_tags[0] else "Workspace";
    try renderReviewStart(req, w, module, active.title, active.cards.len);
    if (active.cards.len > 0) {
        const card = active.cards[0];
        const page = if (card.location_label.len > 0) card.location_label else card.citation_ref;
        try renderCardShell(req, w, card.question, card.answer, card.source_title, page, card.id, active.id, true);
        for (active.cards) |item| {
            const item_page = if (item.location_label.len > 0) item.location_label else item.citation_ref;
            try renderCardData(req, w, item.id, item.question, item.answer, item.source_title, item_page);
        }
    } else {
        try w.writeAll("<div class=\"flash-empty surface\">This deck does not have generated cards yet.</div>");
    }
    try renderPageEnd(w, 0);
}

fn renderPageStart(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\<div class="flash-page" id="cp-flash-review">
        \\  <aside class="deck-sidebar surface"><div><p class="eyebrow">Choose a deck</p><h2>Review queue</h2></div><nav aria-label="Flashcard decks">
    );
}

fn renderDeckButton(req: mer.Request, w: *std.Io.Writer, id: []const u8, title: []const u8, module: []const u8, total: usize, due: usize, active: bool) !void {
    const safe_id = lib.ui.escape(req.allocator, id) catch id;
    const safe_title = lib.ui.escape(req.allocator, title) catch title;
    const safe_module = lib.ui.escape(req.allocator, module) catch module;
    const cls: []const u8 = if (active) "active" else "";
    try w.print("<button class=\"{s}\" type=\"button\" data-deck-url=\"/flashcards?deck={s}\"><span class=\"deck-glyph\">", .{ cls, safe_id });
    try w.writeAll(ICON_LAYERS);
    try w.print("</span><span><strong>{s}</strong><small>{s} · {d} cards</small></span><b>{d}</b></button>", .{ safe_title, safe_module, total, due });
}

fn renderDeckFooter(w: *std.Io.Writer) !void {
    try w.writeAll("</nav><a href=\"/wiki\">Browse connected wiki ");
    try w.writeAll(ICON_ARROW);
    try w.writeAll("</a></aside><section class=\"review-stage\">");
}

fn renderReviewStart(req: mer.Request, w: *std.Io.Writer, module: []const u8, title: []const u8, due: usize) !void {
    const safe_module = lib.ui.escape(req.allocator, module) catch module;
    const safe_title = lib.ui.escape(req.allocator, title) catch title;
    try w.print(
        \\<header class="review-progress"><div><span class="status-pill status-info">{s}</span><strong>{s}</strong></div><div><span><b id="cp-reviewed-count">5</b> reviewed</span><div class="review-bar"><i id="cp-review-bar" style="width:62.5%"></i></div><b>{d} due</b></div></header>
    , .{ safe_module, safe_title, due });
}

fn renderCardShell(req: mer.Request, w: *std.Io.Writer, question: []const u8, answer: []const u8, source: []const u8, page: []const u8, card_id: []const u8, deck_id: []const u8, can_submit: bool) !void {
    const safe_question = lib.ui.escape(req.allocator, question) catch question;
    const safe_answer = lib.ui.escape(req.allocator, answer) catch answer;
    const safe_source = lib.ui.escape(req.allocator, source) catch source;
    const safe_page = lib.ui.escape(req.allocator, page) catch page;
    try w.print(
        \\<article class="flashcard surface" id="cp-flashcard"><div class="card-front"><div class="card-label"><span>Question <b id="cp-card-number">1</b></span><span class="status-pill status-neutral">From your sources</span></div><h2 id="cp-card-question">{s}</h2><p>Think through the invariant, then reveal the evidence-backed answer.</p></div>
        \\<div class="card-answer" id="cp-card-answer" hidden><p class="eyebrow">Answer</p><p id="cp-card-answer-text">{s}</p><div class="card-source"><a class="citation" href="/sources"><span>1</span><span id="cp-card-source">{s}</span></a><span id="cp-card-page">{s}</span><a href="/wiki/balanced-search-trees">Open context →</a></div></div>
        \\<button class="reveal-button" id="cp-reveal-card" type="button"><span>Reveal answer</span><small>or press Space</small></button></article>
        \\<div class="rating-panel" id="cp-rating-panel" hidden><p>How well did you recall it?</p><div>
    , .{ safe_question, safe_answer, safe_source, safe_page });
    if (can_submit) {
        try renderRatingForm(req, w, card_id, deck_id, false, 1, "rate-again", "Again", "&lt; 1 min");
        try renderRatingForm(req, w, card_id, deck_id, true, 2, "rate-hard", "Hard", "2 days");
        try renderRatingForm(req, w, card_id, deck_id, true, 3, "rate-good", "Good", "5 days");
        try renderRatingForm(req, w, card_id, deck_id, true, 5, "rate-easy", "Easy", "12 days");
    } else {
        try renderRatingButton(w, "rate-again", "Again", "&lt; 1 min", "1");
        try renderRatingButton(w, "rate-hard", "Hard", "2 days", "2");
        try renderRatingButton(w, "rate-good", "Good", "5 days", "3");
        try renderRatingButton(w, "rate-easy", "Easy", "12 days", "4");
    }
    try w.writeAll("</div></div><div class=\"review-hint\" id=\"cp-review-hint\"><span>");
    try w.writeAll(ICON_KEYBOARD);
    try w.writeAll("</span><p><strong>Keyboard review</strong><small>Space to reveal · 1–4 to rate</small></p></div><div id=\"cp-flash-data\" hidden>");
}

fn renderRatingForm(req: mer.Request, w: *std.Io.Writer, card_id: []const u8, deck_id: []const u8, correct: bool, confidence: u8, cls: []const u8, label: []const u8, interval: []const u8) !void {
    const safe_card = lib.ui.escape(req.allocator, card_id) catch card_id;
    const safe_deck = lib.ui.escape(req.allocator, deck_id) catch deck_id;
    try w.print("<form action=\"/api/flashcards/attempt\" method=\"post\" data-flash-rate><input type=\"hidden\" name=\"card_id\" value=\"{s}\"><input type=\"hidden\" name=\"deck_id\" value=\"{s}\"><input type=\"hidden\" name=\"correct\" value=\"{s}\"><input type=\"hidden\" name=\"confidence\" value=\"{d}\"><button class=\"{s}\" type=\"submit\"><span>{s}</span><small>{s}</small></button></form>", .{ safe_card, safe_deck, if (correct) "true" else "false", confidence, cls, label, interval });
}

fn renderRatingButton(w: *std.Io.Writer, cls: []const u8, label: []const u8, interval: []const u8, key: []const u8) !void {
    try w.print("<button class=\"{s}\" type=\"button\" data-flash-rate data-key=\"{s}\"><span>{s}</span><small>{s}</small></button>", .{ cls, key, label, interval });
}

fn renderCardData(req: mer.Request, w: *std.Io.Writer, id: []const u8, question: []const u8, answer: []const u8, source: []const u8, page: []const u8) !void {
    const safe_id = lib.ui.escape(req.allocator, id) catch id;
    const safe_question = lib.ui.escape(req.allocator, question) catch question;
    const safe_answer = lib.ui.escape(req.allocator, answer) catch answer;
    const safe_source = lib.ui.escape(req.allocator, source) catch source;
    const safe_page = lib.ui.escape(req.allocator, page) catch page;
    try w.print("<span data-card-id=\"{s}\" data-question=\"{s}\" data-answer=\"{s}\" data-source=\"{s}\" data-page=\"{s}\"></span>", .{ safe_id, safe_question, safe_answer, safe_source, safe_page });
}

fn renderPageEnd(w: *std.Io.Writer, reviewed: usize) !void {
    try w.print(
        \\</div></section><aside class="review-evidence surface"><p class="eyebrow">Session evidence</p><div class="evidence-stat"><strong id="cp-evidence-reviewed">{d}</strong><span>Cards reviewed</span></div><div class="evidence-stat"><strong id="cp-evidence-recall">{s}</strong><span>Recalled today</span></div><div class="evidence-stat"><strong>3</strong><span>Sources used</span></div><hr><p>Review outcomes stay attached to the topic and source that produced each card.</p></aside></div>
    , .{ reviewed, if (reviewed > 0) "80%" else "—" });
}

fn findFixtureDeck(id: []const u8) ?FixtureDeck {
    for (fixture_decks) |deck| if (std.mem.eql(u8, deck.id, id)) return deck;
    return null;
}

fn findLiveDeck(decks: []const lib.types.FlashcardDeckResponse, id: []const u8) ?lib.types.FlashcardDeckResponse {
    for (decks) |deck| if (std.mem.eql(u8, deck.id, id)) return deck;
    return null;
}
