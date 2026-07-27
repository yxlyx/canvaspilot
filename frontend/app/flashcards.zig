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

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

const FlashView = enum { study, create, drafts };

fn flashView(req: mer.Request) FlashView {
    const value = req.queryParam("view") orelse return .study;
    if (std.mem.eql(u8, value, "create")) return .create;
    if (std.mem.eql(u8, value, "drafts")) return .drafts;
    return .study;
}

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);

    const use_mock = lib.m3.isExplicitDemo(req);
    const view = flashView(req);
    const selected_id = req.queryParam("deck") orelse "";
    var live_decks: ?[]const lib.types.FlashcardDeckResponse = null;
    var enrollments: []const lib.types.EnrollmentResponse = &.{};
    var sources: []const lib.types.SourceResponse = &.{};
    var wiki_pages: []const lib.types.WikiPageResponse = &.{};
    if (!use_mock) {
        if (view == .study or view == .drafts) {
            const result = lib.backend.listFlashcardDecks(req.allocator, session.token);
            if (result.value) |parsed| live_decks = parsed.value else return lib.m3.liveError(req, "Flashcards", result.status);
        }
        if (view == .create) {
            const enrollment_result = lib.backend.listEnrollments(req.allocator, session.token);
            if (enrollment_result.value) |parsed| enrollments = parsed.value else return lib.m3.liveError(req, "Flashcard scopes", enrollment_result.status);
            const source_result = lib.backend.listSources(req.allocator, session.token);
            if (source_result.value) |parsed| sources = parsed.value else return lib.m3.liveError(req, "Flashcard sources", source_result.status);
            const wiki_result = lib.backend.listWikiPages(req.allocator, session.token);
            if (wiki_result.value) |parsed| wiki_pages = parsed.value else return lib.m3.liveError(req, "Flashcard wiki pages", wiki_result.status);
        }
    }

    var due: usize = 0;
    if (view == .study) {
        if (live_decks) |decks| {
            for (decks) |deck| if (std.mem.eql(u8, deck.lifecycle, "approved")) {
                due += activeCardCount(deck.cards);
            };
        } else {
            for (lib.mock.decks) |deck| due += deck.due_count;
        }
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("flashcards render failed");
    switch (view) {
        .study => w.print("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">{s}{d} cards due</p><h1 class=\"cp-page-title\">Evidence-backed review</h1><p class=\"cp-page-sub\">Study one source-grounded card at a time.</p></div></header>\n", .{ if (use_mock) "Synthetic demo · " else "", due }) catch return mer.internalError("flashcards render failed"),
        .create => w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Source-grounded study</p><h1 class=\"cp-page-title\">Create flashcards</h1><p class=\"cp-page-sub\">Choose a stable evidence scope, then review every card before it reaches study.</p></div></header>\n") catch return mer.internalError("flashcards render failed"),
        .drafts => w.writeAll("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">Deck history</p><h1 class=\"cp-page-title\">Drafts & published decks</h1><p class=\"cp-page-sub\">Continue a review or revisit an immutable study deck.</p></div></header>\n") catch return mer.internalError("flashcards render failed"),
    }
    renderViewNav(req, w, view) catch return mer.internalError("flashcards render failed");

    switch (view) {
        .create => renderCreateArea(req, w, use_mock, enrollments, sources, wiki_pages) catch return mer.internalError("flashcards render failed"),
        .drafts => {
            if (live_decks) |decks| renderDeckLedger(req, w, decks) catch return mer.internalError("flashcards render failed") else renderFixtureLedger(req, w) catch return mer.internalError("flashcards render failed");
        },
        .study => {
            if (!use_mock) if (req.queryParam("attempt")) |attempt| {
                if (std.mem.eql(u8, attempt, "saved")) {
                    w.writeAll("<div class=\"cp-status-banner cp-status-info\" role=\"status\" aria-live=\"polite\">Practice result saved to learning evidence.</div>\n") catch return mer.internalError("flashcards render failed");
                } else if (std.mem.eql(u8, attempt, "failed")) {
                    w.writeAll("<div class=\"cp-status-banner cp-status-error\" role=\"alert\">Practice result could not be saved. Your answer was not recorded; try again.</div>\n") catch return mer.internalError("flashcards render failed");
                }
            };
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
        },
    }
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn renderViewNav(req: mer.Request, w: *std.Io.Writer, view: FlashView) !void {
    const items = [_]struct { view: FlashView, path: []const u8, label: []const u8 }{
        .{ .view = .study, .path = "/flashcards", .label = "Study" },
        .{ .view = .create, .path = "/flashcards?view=create", .label = "Create" },
        .{ .view = .drafts, .path = "/flashcards?view=drafts", .label = "Drafts & history" },
    };
    try w.writeAll("<nav class=\"cp-local-tabs\" aria-label=\"Flashcard workspace views\"><div>");
    for (items) |item| {
        const href = try lib.m3.demoHref(req.allocator, req, item.path);
        try w.print("<a href=\"{s}\"{s}>{s}</a>", .{ href, if (item.view == view) " aria-current=\"page\"" else "", item.label });
    }
    try w.writeAll("</div></nav>");
}

fn renderCreateArea(req: mer.Request, w: *std.Io.Writer, demo: bool, enrollments: []const lib.types.EnrollmentResponse, sources: []const lib.types.SourceResponse, wiki_pages: []const lib.types.WikiPageResponse) !void {
    var has_enrollment = false;
    for (enrollments) |item| if (!item.archived) {
        has_enrollment = true;
        break;
    };
    var has_source = false;
    for (sources) |item| if (std.ascii.eqlIgnoreCase(item.status, "ready")) {
        has_source = true;
        break;
    };
    const default_scope: []const u8 = if (has_enrollment) "enrollment_id" else if (has_source) "source_ids" else if (wiki_pages.len > 0) "wiki_page_id" else "enrollment_id";

    try w.writeAll("<section class=\"cp-flash-create\" aria-labelledby=\"create-draft-title\" data-flash-create><header><p class=\"eyebrow\">New review deck</p><h2 id=\"create-draft-title\">Build from trusted material</h2><p>Pick one bounded scope. The result opens as a draft, never directly in your study queue.</p></header><form><fieldset");
    if (demo) try w.writeAll(" disabled");
    try w.writeAll("><legend>What should this deck cover?</legend><div class=\"cp-scope-tabs\">");
    const scopes = [_]struct { value: []const u8, label: []const u8, available: bool }{
        .{ .value = "enrollment_id", .label = "Enrollment", .available = has_enrollment },
        .{ .value = "topic_ids", .label = "Topics", .available = has_enrollment },
        .{ .value = "source_ids", .label = "Ready sources", .available = has_source },
        .{ .value = "source_chunk_ids", .label = "Current chunks", .available = has_enrollment },
        .{ .value = "wiki_page_id", .label = "Wiki page", .available = wiki_pages.len > 0 },
    };
    for (scopes) |scope| try w.print("<label><input type=\"radio\" name=\"scope_type\" value=\"{s}\"{s}{s}><span>{s}</span></label>", .{ scope.value, if (std.mem.eql(u8, scope.value, default_scope)) " checked" else "", if (!scope.available and !demo) " disabled" else "", scope.label });
    try w.writeAll("</div><div class=\"cp-scope-selectors\">");
    const enrollment_context_visible = std.mem.eql(u8, default_scope, "enrollment_id") or std.mem.eql(u8, default_scope, "topic_ids") or std.mem.eql(u8, default_scope, "source_chunk_ids");
    try w.print("<label data-scope=\"enrollment_id topic_ids source_chunk_ids\"{s}><span>Enrollment context</span><select name=\"enrollment_id\" size=\"5\" required>", .{if (!enrollment_context_visible) " hidden" else ""});
    for (enrollments) |item| if (!item.archived) try w.print("<option value=\"{s}\">{s} · {s}</option>", .{ lib.ui.escapeSafe(req.allocator, item.id), lib.ui.escapeSafe(req.allocator, item.code), lib.ui.escapeSafe(req.allocator, item.title) });
    try w.print("</select></label><label data-scope=\"topic_ids\"{s}><span>Canonical topics</span><select name=\"topic_ids\" size=\"6\" multiple></select><small>Choose an enrollment first; its canonical topics load here.</small></label>", .{if (!std.mem.eql(u8, default_scope, "topic_ids")) " hidden" else ""});
    try w.print("<label data-scope=\"source_ids\"{s}><span>Ready sources</span><select name=\"source_ids\" size=\"6\" multiple>", .{if (!std.mem.eql(u8, default_scope, "source_ids")) " hidden" else ""});
    var selected_source = false;
    for (sources) |item| if (std.ascii.eqlIgnoreCase(item.status, "ready")) {
        try w.print("<option value=\"{s}\"{s}>{s}</option>", .{ lib.ui.escapeSafe(req.allocator, item.id), if (!selected_source and std.mem.eql(u8, default_scope, "source_ids")) " selected" else "", lib.ui.escapeSafe(req.allocator, item.title) });
        selected_source = true;
    };
    try w.print("</select></label><div data-scope=\"source_chunk_ids\"{s}><label><span>Topic for evidence lookup</span><select name=\"chunk_topic_id\"></select></label><label><span>Ready candidate source</span><select name=\"chunk_source_id\"></select></label><label><span>Current evidence chunks</span><select name=\"source_chunk_ids\" size=\"6\" multiple></select></label><small>Only current chunks from the selected ready source are offered.</small></div><label data-scope=\"wiki_page_id\"{s}><span>Wiki page</span><select name=\"wiki_page_id\" size=\"6\">", .{ if (!std.mem.eql(u8, default_scope, "source_chunk_ids")) " hidden" else "", if (!std.mem.eql(u8, default_scope, "wiki_page_id")) " hidden" else "" });
    for (wiki_pages) |item| try w.print("<option value=\"{s}\">{s}</option>", .{ lib.ui.escapeSafe(req.allocator, item.id), lib.ui.escapeSafe(req.allocator, item.title) });
    try w.writeAll("</select></label></div><div class=\"cp-create-options\"><label class=\"cp-field\"><span>Draft title <small>Optional</small></span><input name=\"deck_title\" maxlength=\"1000\" placeholder=\"e.g. Linked lists review\"></label><label class=\"cp-field\"><span>Cards</span><input name=\"limit\" type=\"number\" min=\"1\" max=\"20\" value=\"10\"></label></div><details class=\"cp-regenerate-option\"><summary>Need a fresh version of an existing scope?</summary><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"regenerate\"><span>Create a linked successor draft<small>The earlier draft remains visible in history.</small></span></label></details><footer class=\"cp-create-footer\"><p class=\"cp-scope-effective\" data-scope-effective role=\"status\">One stable scope will be used.</p><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Create review draft</button></footer></fieldset></form><p data-flash-create-status role=\"status\" aria-live=\"polite\"></p>");
    if (!has_enrollment and !has_source and wiki_pages.len == 0 and !demo) try w.writeAll("<div class=\"cp-empty cp-create-empty\"><div><h3>No ready material yet</h3><p>Process a source or build a Wiki page before creating flashcards.</p><a class=\"cp-btn cp-btn-ghost\" href=\"/sources\">Open sources</a></div></div>");
    if (demo) try w.writeAll("<p class=\"cp-demo-rating-note\">Demo preview · generation is read-only.</p>");
    try w.writeAll("</section>");
}

fn deckLifecycleLabel(lifecycle: []const u8) []const u8 {
    if (std.mem.eql(u8, lifecycle, "draft")) return "In review";
    if (std.mem.eql(u8, lifecycle, "approved")) return "Published";
    if (std.mem.eql(u8, lifecycle, "retired")) return "Retired";
    if (std.mem.eql(u8, lifecycle, "archived")) return "Archived";
    return "Recorded";
}

fn renderDeckLedger(req: mer.Request, w: *std.Io.Writer, decks: []const lib.types.FlashcardDeckResponse) !void {
    try w.writeAll("<div class=\"cp-deck-history\"><section aria-labelledby=\"active-drafts-title\"><header class=\"cp-ledger-heading\"><div><p class=\"eyebrow\">Continue reviewing</p><h2 id=\"active-drafts-title\">Active drafts</h2></div><a class=\"cp-btn cp-btn-primary\" href=\"/flashcards?view=create\">New draft</a></header><div class=\"cp-deck-ledger\">");
    var draft_count: usize = 0;
    for (decks) |deck| if (std.mem.eql(u8, deck.lifecycle, "draft")) {
        draft_count += 1;
        const updated = lib.time.formatRelative(req.allocator, deck.updated_at, lib.time.nowSecs()) catch "—";
        try w.print("<article class=\"cp-deck-ledger-row\"><div><span class=\"status-pill status-neutral\">In review</span><h3>{s}</h3><p>{d} cards · revision {d} · updated {s}</p></div><a class=\"cp-btn cp-btn-ghost\" href=\"/flashcards/drafts/{s}\">Review draft</a></article>", .{ lib.ui.escapeSafe(req.allocator, deck.title), deck.card_count, deck.revision, lib.ui.escapeSafe(req.allocator, updated), lib.ui.escapeSafe(req.allocator, deck.id) });
    };
    if (draft_count == 0) try w.writeAll("<div class=\"cp-empty-copy\"><h3>No drafts waiting</h3><p>Create a deck from a ready source when you are ready.</p></div>");
    try w.writeAll("</div></section><section aria-labelledby=\"deck-history-title\"><header class=\"cp-ledger-heading\"><div><p class=\"eyebrow\">Study record</p><h2 id=\"deck-history-title\">Published history</h2></div></header><div class=\"cp-deck-ledger\">");
    var history_count: usize = 0;
    for (decks) |deck| if (!std.mem.eql(u8, deck.lifecycle, "draft")) {
        history_count += 1;
        const updated = lib.time.formatRelative(req.allocator, deck.updated_at, lib.time.nowSecs()) catch "—";
        try w.print("<article class=\"cp-deck-ledger-row\"><div><span class=\"status-pill status-neutral\">{s}</span><h3>{s}</h3><p>{d} cards · revision {d} · updated {s}</p></div><div class=\"cp-action-row\">", .{ deckLifecycleLabel(deck.lifecycle), lib.ui.escapeSafe(req.allocator, deck.title), deck.card_count, deck.revision, lib.ui.escapeSafe(req.allocator, updated) });
        if (std.mem.eql(u8, deck.lifecycle, "approved")) try w.print("<a class=\"cp-btn cp-btn-primary\" href=\"/flashcards?deck={s}\">Study deck</a>", .{lib.ui.escapeSafe(req.allocator, deck.id)});
        try w.print("<a class=\"cp-btn cp-btn-ghost\" href=\"/flashcards/drafts/{s}\">View record</a></div></article>", .{lib.ui.escapeSafe(req.allocator, deck.id)});
    };
    if (history_count == 0) try w.writeAll("<div class=\"cp-empty-copy\"><h3>No published decks yet</h3><p>Approved drafts appear here as an immutable study record.</p></div>");
    try w.writeAll("</div></section></div>");
}

fn renderFixtureLedger(req: mer.Request, w: *std.Io.Writer) !void {
    try w.writeAll("<div class=\"cp-deck-history\"><section aria-labelledby=\"active-drafts-title\"><header class=\"cp-ledger-heading\"><div><p class=\"eyebrow\">Continue reviewing</p><h2 id=\"active-drafts-title\">Active drafts</h2></div></header><div class=\"cp-deck-ledger\"><div class=\"cp-empty-copy\"><h3>No demo drafts waiting</h3><p>Draft mutations are unavailable in the read-only preview.</p></div></div></section><section aria-labelledby=\"deck-history-title\"><header class=\"cp-ledger-heading\"><div><p class=\"eyebrow\">Study record</p><h2 id=\"deck-history-title\">Published history</h2></div></header><div class=\"cp-deck-ledger\">");
    for (lib.mock.decks) |deck| {
        const path = try std.fmt.allocPrint(req.allocator, "/flashcards?deck={s}", .{deck.id});
        const href = try lib.m3.demoHref(req.allocator, req, path);
        try w.print("<article class=\"cp-deck-ledger-row\"><div><span class=\"status-pill status-neutral\">Published</span><h3>{s}</h3><p>{d} cards · demo record</p></div><a class=\"cp-btn cp-btn-ghost\" href=\"{s}\">Study deck</a></article>", .{ lib.ui.escapeSafe(req.allocator, deck.title), deck.card_count, href });
    }
    try w.writeAll("</div></section></div>");
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
        try renderCardShell(req, w, card.question, card.answer, card.citation.title, card.citation.snippet, deck.source_id, card.id, deck.id, false);
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
    var active: ?lib.types.FlashcardDeckResponse = null;
    for (decks) |deck| {
        if (!std.mem.eql(u8, deck.lifecycle, "approved")) continue;
        if ((selected_id.len == 0 and active == null) or std.mem.eql(u8, deck.id, selected_id)) active = deck;
    }
    const active_id = if (active) |deck| deck.id else "";
    try renderPageStart(w);
    for (decks) |deck| {
        if (!std.mem.eql(u8, deck.lifecycle, "approved")) continue;
        const module = if (deck.topic_tags.len > 0) deck.topic_tags[0] else "Workspace";
        const active_cards = activeCardCount(deck.cards);
        try renderDeckButton(req, w, deck.id, deck.title, module, deck.description, deck.generation_scope, deck.updated_at, deck.source_ids.len, active_cards, active_cards, std.mem.eql(u8, deck.id, active_id));
    }
    try renderDeckFooter(w, "/wiki");
    const deck = active orelse {
        try renderReviewStart(req, w, "Practice", "No approved deck selected", 0);
        try w.writeAll("<div class=\"flash-empty surface\" role=\"status\">No practice-ready approved decks are available. Review and publish a draft first.</div></section><aside class=\"review-evidence surface\"><p class=\"eyebrow\">Session evidence</p><p>No review evidence yet.</p></aside></div>");
        return;
    };
    const module = if (deck.topic_tags.len > 0) deck.topic_tags[0] else "Workspace";
    const active_cards = activeCardCount(deck.cards);
    try renderReviewStart(req, w, module, deck.title, active_cards);
    if (firstActiveCard(deck.cards)) |card| {
        const page = if (card.location_label.len > 0) card.location_label else card.citation_ref;
        try renderCardShell(req, w, card.question, card.answer, card.source_title, page, card.source_id orelse "", card.id, deck.id, true);
        for (deck.cards) |item| {
            if (!std.mem.eql(u8, item.state, "active")) continue;
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

fn renderCardShell(req: mer.Request, w: *std.Io.Writer, question: []const u8, answer: []const u8, source: []const u8, page: []const u8, source_id: []const u8, card_id: []const u8, deck_id: []const u8, can_submit: bool) !void {
    const safe_question = lib.ui.escapeSafe(req.allocator, question);
    const safe_answer = lib.ui.escapeSafe(req.allocator, answer);
    const safe_source = lib.ui.escapeSafe(req.allocator, source);
    const safe_page = lib.ui.escapeSafe(req.allocator, page);
    const source_path = if (safeUuid(source_id)) try std.fmt.allocPrint(req.allocator, "/sources?source={s}", .{source_id}) else "/sources";
    const sources_href = try lib.m3.demoHref(req.allocator, req, source_path);
    try w.print(
        \\<article class="flashcard surface" id="cp-flashcard"><div class="card-front"><div class="card-label"><span>Question <b id="cp-card-number">1</b></span><span class="status-pill status-neutral">From your sources</span></div><h2 id="cp-card-question">{s}</h2><p>Think through the invariant, then reveal the evidence-backed answer.</p></div>
        \\<details id="cp-card-details"><summary class="reveal-button" id="cp-reveal-card" style="list-style:none"><span>Reveal answer</span><small>or press Space</small></summary>
        \\<div class="card-answer" id="cp-card-answer"><p class="eyebrow">Answer</p><p id="cp-card-answer-text">{s}</p><div class="card-source"><a class="citation" id="cp-card-source-link" href="{s}"><span>1</span><span id="cp-card-source">{s}</span></a><span id="cp-card-page">{s}</span><a id="cp-card-context-link" href="{s}">Open context →</a></div></div>
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
    try w.writeAll("</div>");
    if (can_submit) try w.writeAll("<button class=\"cp-skip-rating\" id=\"cp-skip-card\" type=\"button\">Skip for now</button>");
    try w.writeAll("</div></details></article><div class=\"review-hint\" id=\"cp-review-hint\"><span>");
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
    try w.print("<form action=\"/api/flashcards\" method=\"post\" data-flash-rate><input type=\"hidden\" name=\"card_id\" value=\"{s}\"><input type=\"hidden\" name=\"deck_id\" value=\"{s}\"><input type=\"hidden\" name=\"rating\" value=\"{s}\"><input type=\"hidden\" name=\"correct\" value=\"{s}\"><input type=\"hidden\" name=\"confidence\" value=\"{d}\"><button type=\"submit\" aria-label=\"{s}\"><span>{s}</span><small>{s}</small></button></form>", .{ safe_card, safe_deck, label, if (correct) "true" else "false", confidence, label, label, interval });
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
        \\</div></section><aside class="review-evidence surface"><p class="eyebrow">This session</p><div class="evidence-stat"><strong id="cp-evidence-reviewed">{d}</strong><span>Persisted ratings</span></div><div class="evidence-stat"><strong id="cp-evidence-recalled">0</strong><span>Recalled (Hard, Good, or Easy)</span></div><div class="evidence-stat"><strong id="cp-evidence-missed">0</strong><span>Not recalled (Again)</span></div><div class="evidence-stat"><strong id="cp-evidence-confidence">—</strong><span>Average saved confidence (1–5)</span></div><div class="evidence-stat"><strong id="cp-evidence-skipped">0</strong><span>Skipped locally</span></div><hr><p>Only backend-confirmed ratings count as persisted, recalled, not recalled, or confidence. Skips are not learning evidence and remain local to this page.</p></aside></div>
    , .{reviewed});
}

fn activeCardCount(cards: []const lib.types.FlashcardResponse) usize {
    var count: usize = 0;
    for (cards) |card| if (std.mem.eql(u8, card.state, "active")) {
        count += 1;
    };
    return count;
}

fn firstActiveCard(cards: []const lib.types.FlashcardResponse) ?lib.types.FlashcardResponse {
    for (cards) |card| if (std.mem.eql(u8, card.state, "active")) return card;
    return null;
}

fn findMockDeck(id: []const u8) ?lib.types.FlashcardDeck {
    for (lib.mock.decks) |deck| if (std.mem.eql(u8, deck.id, id)) return deck;
    return null;
}

fn findLiveDeck(decks: []const lib.types.FlashcardDeckResponse, id: []const u8) ?lib.types.FlashcardDeckResponse {
    for (decks) |deck| if (std.mem.eql(u8, deck.id, id)) return deck;
    return null;
}

test "approved practice excludes discarded draft cards" {
    const cards = [_]lib.types.FlashcardResponse{
        .{ .id = "active", .deck_id = "deck", .user_id = "user", .question = "Q1", .answer = "A1" },
        .{ .id = "discarded", .deck_id = "deck", .user_id = "user", .question = "Q2", .answer = "A2", .state = "discarded" },
    };
    try std.testing.expectEqual(@as(usize, 1), activeCardCount(&cards));
    try std.testing.expectEqualStrings("active", firstActiveCard(&cards).?.id);
}
