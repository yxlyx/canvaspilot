// app/flashcards.zig — source-backed flashcard review.
//
// Live sessions use backend decks; fixtures are available only in explicit
// demo mode.

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

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);

    const use_mock = lib.m3.isExplicitDemo(req);
    const selected_id = req.queryParam("deck") orelse "";
    var live_decks: ?[]const lib.types.FlashcardDeckResponse = null;
    if (!use_mock) {
        const result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (result.value) |parsed| {
            live_decks = parsed.value;
        } else {
            return lib.m3.liveError(req, "Flashcards", result.status);
        }
    }

    var due: usize = 0;
    if (live_decks) |decks| {
        for (decks) |deck| due += deck.cards.len;
    } else {
        for (lib.mock.decks) |deck| due += deck.due_count;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("flashcards render failed");
    w.print("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">{s}{d} cards due</p><h1 class=\"cp-page-title\">Evidence-backed review</h1></div></header>\n", .{ if (use_mock) "Synthetic demo · " else "", due }) catch return mer.internalError("flashcards render failed");

    if (!use_mock) {
        if (req.queryParam("attempt")) |attempt| {
            if (std.mem.eql(u8, attempt, "saved")) {
                w.writeAll("<div class=\"cp-status-banner cp-status-info\" role=\"status\" aria-live=\"polite\">Practice result saved to learning evidence.</div>\n") catch return mer.internalError("flashcards render failed");
            } else if (std.mem.eql(u8, attempt, "failed")) {
                w.writeAll("<div class=\"cp-status-banner cp-status-error\" role=\"alert\">Practice result could not be saved. Your answer was not recorded; try again.</div>\n") catch return mer.internalError("flashcards render failed");
            }
        }
    }

    if (live_decks) |decks| {
        if (decks.len == 0) {
            if (selected_id.len > 0) {
                renderPageStart(w) catch return mer.internalError("flashcards render failed");
                renderDeckFooter(w, "/wiki") catch return mer.internalError("flashcards render failed");
                renderDeckNotFound(req, w) catch return mer.internalError("flashcards render failed");
            } else {
                renderEmptyPage(w) catch return mer.internalError("flashcards render failed");
            }
        } else {
            renderLivePage(req, w, decks, selected_id) catch return mer.internalError("flashcards render failed");
        }
    } else {
        renderFixturePage(req, w, selected_id) catch return mer.internalError("flashcards render failed");
    }
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderEmptyPage(w: *std.Io.Writer) !void {
    try renderPageStart(w);
    try renderDeckFooter(w, "/wiki");
    try w.writeAll("<div class=\"flash-empty surface\">No flashcard decks have been generated yet.</div></section><aside class=\"review-evidence surface\"><p class=\"eyebrow\">Session evidence</p><p>No review evidence yet.</p></aside></div>");
}

fn renderDeckNotFound(req: mer.Request, w: *std.Io.Writer) !void {
    try renderReviewStart(req, w, "Review queue", "Deck not found", 0);
    try w.writeAll("<div class=\"flash-empty surface\" role=\"status\"><strong>Deck not found.</strong> No deck matches the requested id. Pick one from the list.</div></section><aside class=\"review-evidence surface\"><p class=\"eyebrow\">Session evidence</p><p>No review evidence yet.</p></aside></div>");
}

fn renderFixturePage(req: mer.Request, w: *std.Io.Writer, selected_id: []const u8) !void {
    const active: ?lib.types.FlashcardDeck = if (selected_id.len == 0) lib.mock.decks[0] else findMockDeck(selected_id);
    const active_id = if (active) |deck| deck.id else "";
    try renderPageStart(w);
    for (lib.mock.decks) |deck| {
        const module = if (deck.topics.len > 0) deck.topics[0] else "Workspace";
        try renderDeckButton(req, w, deck.id, deck.title, module, deck.description, "demo", deck.updated_at, 1, deck.card_count, deck.due_count, std.mem.eql(u8, deck.id, active_id));
    }
    const wiki_href = try lib.m3.demoHref(req.allocator, req, "/wiki");
    try renderDeckFooter(w, wiki_href);
    const deck = active orelse {
        try renderDeckNotFound(req, w);
        return;
    };
    const module = if (deck.topics.len > 0) deck.topics[0] else "Workspace";
    try renderReviewStart(req, w, module, deck.title, deck.due_count);

    var first: ?lib.types.Flashcard = null;
    for (lib.mock.flashcards) |card| if (std.mem.eql(u8, card.deck_id, deck.id)) {
        first = card;
        break;
    };
    if (first) |card| {
        try renderCardShell(req, w, card.question, card.answer, card.citation.title, card.citation.snippet, card.id, deck.id, false);
        for (lib.mock.flashcards) |item| {
            if (!std.mem.eql(u8, item.deck_id, deck.id)) continue;
            try renderCardData(req, w, item.id, item.question, item.answer, item.citation.title, item.citation.snippet, item.topic, item.citation.url, item.citation.snippet, "", "", deck.source_id, "");
        }
    } else {
        try w.writeAll("<div class=\"flash-empty surface\">This deck does not have generated cards yet.</div>");
    }
    try renderPageEnd(w, 0);
}

fn renderLivePage(req: mer.Request, w: *std.Io.Writer, decks: []const lib.types.FlashcardDeckResponse, selected_id: []const u8) !void {
    const active: ?lib.types.FlashcardDeckResponse = if (selected_id.len == 0) decks[0] else findLiveDeck(decks, selected_id);
    const active_id = if (active) |deck| deck.id else "";
    try renderPageStart(w);
    for (decks) |deck| {
        const module = if (deck.topic_tags.len > 0) deck.topic_tags[0] else "Workspace";
        try renderDeckButton(req, w, deck.id, deck.title, module, deck.description, deck.generation_scope, deck.updated_at, deck.source_ids.len, deck.card_count, deck.cards.len, std.mem.eql(u8, deck.id, active_id));
    }
    try renderDeckFooter(w, "/wiki");
    const deck = active orelse {
        try renderDeckNotFound(req, w);
        return;
    };
    const module = if (deck.topic_tags.len > 0) deck.topic_tags[0] else "Workspace";
    try renderReviewStart(req, w, module, deck.title, deck.cards.len);
    if (deck.cards.len > 0) {
        const card = deck.cards[0];
        const page = if (card.location_label.len > 0) card.location_label else card.citation_ref;
        try renderCardShell(req, w, card.question, card.answer, card.source_title, page, card.id, deck.id, true);
        for (deck.cards) |item| {
            const item_page = if (item.location_label.len > 0) item.location_label else item.citation_ref;
            try renderCardData(req, w, item.id, item.question, item.answer, item.source_title, item_page, item.topic_tag, item.citation_ref, item.location_label, item.source_id orelse "", item.source_chunk_id orelse "", item.wiki_page_id orelse "", item.card_type);
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

fn renderDeckButton(req: mer.Request, w: *std.Io.Writer, id: []const u8, title: []const u8, module: []const u8, description: []const u8, scope: []const u8, updated_at: []const u8, source_count: usize, total: usize, due: usize, active: bool) !void {
    const safe_id = lib.ui.escape(req.allocator, lib.m3.safeId(id, "")) catch "";
    const safe_title = lib.ui.escapeSafe(req.allocator, title);
    const safe_module = lib.ui.escapeSafe(req.allocator, module);
    const safe_description = lib.ui.escapeSafe(req.allocator, description);
    const safe_scope = lib.ui.escapeSafe(req.allocator, scope);
    const safe_updated = lib.ui.escapeSafe(req.allocator, updated_at);
    const path = try std.fmt.allocPrint(req.allocator, "/flashcards?deck={s}", .{safe_id});
    const href = try lib.m3.demoHref(req.allocator, req, path);
    const cls: []const u8 = if (active) "cp-deck-row active" else "cp-deck-row";
    const current: []const u8 = if (active) " aria-current=\"true\"" else "";
    try w.print("<a class=\"{s}\" href=\"{s}\" data-deck-url=\"{s}\" data-description=\"{s}\" data-generation-scope=\"{s}\" data-updated-at=\"{s}\" data-source-count=\"{d}\"{s}><span class=\"deck-glyph\">", .{ cls, href, href, safe_description, safe_scope, safe_updated, source_count, current });
    try w.writeAll(ICON_LAYERS);
    try w.print("</span><span><strong>{s}</strong><small>{s} · {d} cards</small></span><b>{d}</b></a>", .{ safe_title, safe_module, total, due });
}

fn renderDeckFooter(w: *std.Io.Writer, wiki_href: []const u8) !void {
    try w.print("</nav><a href=\"{s}\">Browse connected wiki ", .{wiki_href});
    try w.writeAll(ICON_ARROW);
    try w.writeAll("</a></aside><section class=\"review-stage\">");
}

fn renderReviewStart(req: mer.Request, w: *std.Io.Writer, module: []const u8, title: []const u8, due: usize) !void {
    const safe_module = lib.ui.escapeSafe(req.allocator, module);
    const safe_title = lib.ui.escapeSafe(req.allocator, title);
    try w.print(
        \\<header class="review-progress"><div><span class="status-pill status-info">{s}</span><strong>{s}</strong></div><div><span><b id="cp-reviewed-count">0</b> reviewed</span><div class="review-bar"><i id="cp-review-bar" style="width:0%"></i></div><b>{d} due</b></div></header>
    , .{ safe_module, safe_title, due });
}

fn renderCardShell(req: mer.Request, w: *std.Io.Writer, question: []const u8, answer: []const u8, source: []const u8, page: []const u8, card_id: []const u8, deck_id: []const u8, can_submit: bool) !void {
    const safe_question = lib.ui.escapeSafe(req.allocator, question);
    const safe_answer = lib.ui.escapeSafe(req.allocator, answer);
    const safe_source = lib.ui.escapeSafe(req.allocator, source);
    const safe_page = lib.ui.escapeSafe(req.allocator, page);
    const sources_href = try lib.m3.demoHref(req.allocator, req, "/sources");
    try w.print(
        \\<article class="flashcard surface" id="cp-flashcard"><div class="card-front"><div class="card-label"><span>Question <b id="cp-card-number">1</b></span><span class="status-pill status-neutral">From your sources</span></div><h2 id="cp-card-question">{s}</h2><p>Think through the invariant, then reveal the evidence-backed answer.</p></div>
        \\<details id="cp-card-details"><summary class="reveal-button" id="cp-reveal-card" style="list-style:none"><span>Reveal answer</span><small>or press Space</small></summary>
        \\<div class="card-answer" id="cp-card-answer"><p class="eyebrow">Answer</p><p id="cp-card-answer-text">{s}</p><div class="card-source"><a class="citation" href="{s}"><span>1</span><span id="cp-card-source">{s}</span></a><span id="cp-card-page">{s}</span><a href="{s}">Open context →</a></div></div>
        \\<div class="rating-panel" id="cp-rating-panel"><p>How well did you recall it?</p>
    , .{ safe_question, safe_answer, sources_href, safe_source, safe_page, sources_href });
    if (!can_submit) try w.writeAll("<p class=\"cp-demo-rating-note\" role=\"note\">Demo preview: ratings are disabled and are not saved.</p>");
    try w.writeAll("<div>");
    if (can_submit) {
        try renderRatingForm(req, w, card_id, deck_id, false, 1, "Again", "Needs another look");
        try renderRatingForm(req, w, card_id, deck_id, true, 2, "Hard", "Low confidence");
        try renderRatingForm(req, w, card_id, deck_id, true, 3, "Good", "Recalled");
        try renderRatingForm(req, w, card_id, deck_id, true, 5, "Easy", "Strong recall");
    } else {
        try renderRatingButton(w, "Again", "Needs another look");
        try renderRatingButton(w, "Hard", "Low confidence");
        try renderRatingButton(w, "Good", "Recalled");
        try renderRatingButton(w, "Easy", "Strong recall");
    }
    try w.writeAll("</div></div></details></article><div class=\"review-hint\" id=\"cp-review-hint\"><span>");
    try w.writeAll(ICON_KEYBOARD);
    if (can_submit) {
        try w.writeAll("</span><p><strong>Keyboard review</strong><small>Space to reveal · 1–4 to advance</small></p></div><div id=\"cp-flash-data\" hidden>");
    } else {
        try w.writeAll("</span><p><strong>Keyboard review</strong><small>Space to reveal · ratings disabled in demo</small></p></div><div id=\"cp-flash-data\" hidden>");
    }
}

fn renderRatingForm(req: mer.Request, w: *std.Io.Writer, card_id: []const u8, deck_id: []const u8, correct: bool, confidence: u8, label: []const u8, interval: []const u8) !void {
    const safe_card = lib.ui.escape(req.allocator, lib.m3.safeId(card_id, "")) catch "";
    const safe_deck = lib.ui.escape(req.allocator, lib.m3.safeId(deck_id, "")) catch "";
    try w.print("<form action=\"/api/flashcards/attempt\" method=\"post\" data-flash-rate><input type=\"hidden\" name=\"card_id\" value=\"{s}\"><input type=\"hidden\" name=\"deck_id\" value=\"{s}\"><input type=\"hidden\" name=\"correct\" value=\"{s}\"><input type=\"hidden\" name=\"confidence\" value=\"{d}\"><button type=\"submit\" aria-label=\"{s}\"><span>{s}</span><small>{s}</small></button></form>", .{ safe_card, safe_deck, if (correct) "true" else "false", confidence, label, label, interval });
}

fn renderRatingButton(w: *std.Io.Writer, label: []const u8, interval: []const u8) !void {
    try w.print("<button type=\"button\" aria-label=\"{s}\" disabled><span>{s}</span><small>{s}</small></button>", .{ label, label, interval });
}

fn renderCardData(req: mer.Request, w: *std.Io.Writer, id: []const u8, question: []const u8, answer: []const u8, source: []const u8, page: []const u8, topic: []const u8, citation_ref: []const u8, location: []const u8, source_id: []const u8, source_chunk_id: []const u8, wiki_page_id: []const u8, card_type: []const u8) !void {
    const values = .{
        lib.ui.escapeSafe(req.allocator, id),
        lib.ui.escapeSafe(req.allocator, question),
        lib.ui.escapeSafe(req.allocator, answer),
        lib.ui.escapeSafe(req.allocator, source),
        lib.ui.escapeSafe(req.allocator, page),
        lib.ui.escapeSafe(req.allocator, topic),
        lib.ui.escapeSafe(req.allocator, citation_ref),
        lib.ui.escapeSafe(req.allocator, location),
        lib.ui.escapeSafe(req.allocator, source_id),
        lib.ui.escapeSafe(req.allocator, source_chunk_id),
        lib.ui.escapeSafe(req.allocator, wiki_page_id),
        lib.ui.escapeSafe(req.allocator, card_type),
    };
    try w.print("<span data-card-id=\"{s}\" data-question=\"{s}\" data-answer=\"{s}\" data-source=\"{s}\" data-page=\"{s}\" data-topic=\"{s}\" data-citation-ref=\"{s}\" data-location=\"{s}\" data-source-id=\"{s}\" data-source-chunk-id=\"{s}\" data-wiki-page-id=\"{s}\" data-card-type=\"{s}\"></span>", values);
}

fn renderPageEnd(w: *std.Io.Writer, reviewed: usize) !void {
    try w.print(
        \\</div></section><aside class="review-evidence surface"><p class="eyebrow">Session evidence</p><div class="evidence-stat"><strong id="cp-evidence-reviewed">{d}</strong><span>Cards reviewed</span></div><div class="evidence-stat"><strong id="cp-evidence-recall">{s}</strong><span>Recalled today</span></div><div class="evidence-stat"><strong>—</strong><span>Sources used</span></div><hr><p>Review outcomes stay attached to the topic and source that produced each card.</p></aside></div>
    , .{ reviewed, if (reviewed > 0) "80%" else "—" });
}

fn findMockDeck(id: []const u8) ?lib.types.FlashcardDeck {
    for (lib.mock.decks) |deck| if (std.mem.eql(u8, deck.id, id)) return deck;
    return null;
}

fn findLiveDeck(decks: []const lib.types.FlashcardDeckResponse, id: []const u8) ?lib.types.FlashcardDeckResponse {
    for (decks) |deck| if (std.mem.eql(u8, deck.id, id)) return deck;
    return null;
}
