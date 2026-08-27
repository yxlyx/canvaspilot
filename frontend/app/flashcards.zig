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
const ICON_SCOPE = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"8\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M12 2v3M12 19v3M2 12h3M19 12h3\"/></svg>";
const ICON_TOPIC = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"6\" cy=\"6\" r=\"2\"/><circle cx=\"18\" cy=\"7\" r=\"2\"/><circle cx=\"12\" cy=\"18\" r=\"2\"/><path d=\"m8 7 8 1M7 8l4 8M17 9l-4 7\"/></svg>";
const ICON_FILE = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z\"/><path d=\"M14 2v6h6M8 13h8M8 17h6\"/></svg>";
const ICON_WIKI = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M12 7v14\"/><path d=\"M3 18a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h5a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3Z\"/><path d=\"M21 18a1 1 0 0 0 1-1V4a1 1 0 0 0-1-1h-5a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3Z\"/></svg>";
const ICON_CLOCK = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 7v5l3 2\"/></svg>";
const ICON_TRASH = "<svg aria-hidden=\"true\" viewBox=\"0 0 24 24\"><path d=\"M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 10v6M14 10v6\"/></svg>";

fn safeUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

pub fn render(req: mer.Request) mer.Response {
    const session = lib.session.fromRequest(req);
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);

    const use_mock = lib.m3.isExplicitDemo(req);
    const selected_id = req.queryParam("deck") orelse "";
    var live_decks: ?[]const lib.types.FlashcardDeckResponse = null;
    var enrollments: []const lib.types.EnrollmentResponse = &.{};
    var sources: []const lib.types.SourceResponse = &.{};
    var wiki_pages: []const lib.types.WikiPageResponse = &.{};
    var provider_state: lib.provider_ui.State = if (use_mock) .active else .unavailable;
    const demo_enrollments = [_]lib.types.EnrollmentResponse{.{
        .id = "11111111-1111-1111-1111-111111111111",
        .code = "CS2030S",
        .title = "Programming Methodology II",
        .academic_year = "2025-2026",
        .semester = 1,
        .provenance = "illustrative",
        .import_method = "fixture",
        .topic_state = "ready",
        .evidence_warning = null,
        .archived = false,
        .institution = "NUS",
        .provider = "fixture",
        .provider_version = "1",
        .provider_academic_year = "2025-2026",
        .source_url = "",
        .provider_fetched_at = "2026-05-18T10:30:00Z",
        .payload_sha256 = "illustrative",
    }};
    const demo_sources = [_]lib.types.SourceResponse{
        .{ .id = "21111111-1111-1111-1111-111111111111", .user_id = lib.mock.me.id, .enrollment_id = demo_enrollments[0].id, .source_type = "markdown", .title = "Lecture 9: Immutable Lists and Lazy Streams", .status = "ready" },
        .{ .id = "31111111-1111-1111-1111-111111111111", .user_id = lib.mock.me.id, .enrollment_id = demo_enrollments[0].id, .source_type = "assignment", .title = "Lab 6: Functional Collections Brief", .status = "ready" },
    };
    const demo_wiki_pages = [_]lib.types.WikiPageResponse{.{ .id = "41111111-1111-1111-1111-111111111111", .user_id = lib.mock.me.id, .slug = "immutable-lists", .title = "Immutable Lists and Lazy Streams", .markdown = "" }};
    if (use_mock) {
        enrollments = &demo_enrollments;
        sources = &demo_sources;
        wiki_pages = &demo_wiki_pages;
    } else {
        const result = lib.backend.listFlashcardDecks(req.allocator, session.token);
        if (result.value) |parsed| live_decks = parsed.value else return lib.m3.liveError(req, "Flashcards", result.status);
        const enrollment_result = lib.backend.listEnrollments(req.allocator, session.token);
        if (enrollment_result.value) |parsed| enrollments = parsed.value else return lib.m3.liveError(req, "Flashcard scopes", enrollment_result.status);
        const source_result = lib.backend.listSources(req.allocator, session.token);
        if (source_result.value) |parsed| sources = parsed.value else return lib.m3.liveError(req, "Flashcard sources", source_result.status);
        const wiki_result = lib.backend.listWikiPages(req.allocator, session.token);
        if (wiki_result.value) |parsed| wiki_pages = parsed.value else return lib.m3.liveError(req, "Flashcard wiki pages", wiki_result.status);
        const provider_result = lib.backend.providerSettings(req.allocator, session.token);
        if (provider_result.value) |items| provider_state = lib.provider_ui.classify(items.value) else if (provider_result.status == 401) return lib.m3.liveError(req, "Flashcards", 401);
    }

    var due: usize = 0;
    if (live_decks) |decks| {
        for (decks) |deck| if (std.mem.eql(u8, deck.lifecycle, "approved")) {
            due += activeCardCount(deck.cards);
        };
    } else {
        for (lib.mock.decks) |deck| due += deck.due_count;
    }

    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    lib.m3.demoMarker(req, w) catch return mer.internalError("flashcards render failed");
    w.print("<header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">{s}{d} approved cards available</p><h1 class=\"cp-page-title\">Flashcard workspace</h1><p class=\"cp-page-sub\">Create a source-bounded draft, review every card, then explicitly start studying an approved deck.</p></div></header>\n", .{ if (use_mock) "Synthetic demo · " else "", due }) catch return mer.internalError("flashcards render failed");
    renderCreateArea(req, w, use_mock, provider_state, enrollments, sources, wiki_pages) catch return mer.internalError("flashcards render failed");

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

fn renderCreateArea(req: mer.Request, w: *std.Io.Writer, demo: bool, provider_state: lib.provider_ui.State, enrollments: []const lib.types.EnrollmentResponse, sources: []const lib.types.SourceResponse, wiki_pages: []const lib.types.WikiPageResponse) !void {
    try w.writeAll("<section class=\"cp-flash-create surface\" aria-labelledby=\"create-draft-title\" data-flash-create><header><div><p class=\"eyebrow\">New study material</p><h2 id=\"create-draft-title\">Create a review draft</h2><p>Choose a bounded evidence scope, create a draft, then review every card before practice.</p></div></header>");
    if (provider_state != .active) {
        try lib.provider_ui.renderBoundary(w, provider_state, "Your existing drafts, approved decks, citations, and review practice remain available below.");
        try w.writeAll("</section>");
        return;
    }
    try w.writeAll("<form");
    if (demo) try w.writeAll(" data-demo");
    try w.writeAll("><fieldset><legend class=\"sr-only\">Create a source-backed flashcard draft</legend><section class=\"cp-flash-step\"><header><span>1</span><div><h3>Choose scope</h3><p>Pick the kind of evidence that should bound this draft.</p></div></header><div class=\"cp-scope-cards\">");
    const scopes = [_]struct { value: []const u8, title: []const u8, detail: []const u8, icon: []const u8 }{
        .{ .value = "enrollment_id", .title = "Enrollment", .detail = "One complete module scope", .icon = ICON_SCOPE },
        .{ .value = "topic_ids", .title = "Topics", .detail = "Selected canonical concepts", .icon = ICON_TOPIC },
        .{ .value = "source_ids", .title = "Ready sources", .detail = "One or more indexed documents", .icon = ICON_FILE },
        .{ .value = "source_chunk_ids", .title = "Current chunks", .detail = "Specific evidence excerpts", .icon = ICON_LAYERS },
        .{ .value = "wiki_page_id", .title = "Wiki page", .detail = "One compiled article", .icon = ICON_WIKI },
    };
    for (scopes, 0..) |scope, index| try w.print("<label><input type=\"radio\" name=\"scope_type\" value=\"{s}\"{s}><span class=\"cp-scope-card-icon\">{s}</span><span><strong>{s}</strong><small>{s}</small></span></label>", .{ scope.value, if (index == 0) " checked" else "", scope.icon, scope.title, scope.detail });
    try w.writeAll("</div></section><section class=\"cp-flash-step\"><header><span>2</span><div><h3>Select evidence</h3><p>Only the selected evidence is sent for draft creation.</p></div></header><div class=\"cp-scope-selectors\">");
    try w.writeAll("<div data-scope=\"enrollment_id\"><div class=\"cp-choice-grid\" data-choice-list=\"enrollment_id\">");
    var first_enrollment = true;
    for (enrollments) |item| if (!item.archived) {
        try renderChoice(req, w, "radio", "enrollment_id", item.id, item.code, item.title, first_enrollment);
        first_enrollment = false;
    };
    if (first_enrollment) try w.writeAll("<div class=\"cp-choice-empty\"><strong>No enrollment is available</strong><span>Import a module before creating an enrollment-scoped draft.</span><a href=\"/settings/learning\">Manage modules</a></div>");
    try w.writeAll("</div></div><div data-scope=\"topic_ids\" hidden><div class=\"cp-choice-grid\" data-choice-list=\"topic_ids\"></div><p class=\"cp-empty-copy\" data-choice-empty>Select an enrollment first; its canonical topics will appear here.</p></div><div data-scope=\"source_ids\" hidden><div class=\"cp-choice-grid\" data-choice-list=\"source_ids\">");
    var ready_sources: usize = 0;
    for (sources) |item| if (std.ascii.eqlIgnoreCase(item.status, "ready")) {
        ready_sources += 1;
        try renderChoice(req, w, "checkbox", "source_ids", item.id, item.title, "Ready for cited study", false);
    };
    if (ready_sources == 0) try w.writeAll("<div class=\"cp-choice-empty\"><strong>No ready source is available</strong><span>Add or finish processing a source first.</span><a href=\"/sources\">Open Sources</a></div>");
    try w.writeAll("</div></div><div data-scope=\"source_chunk_ids\" hidden><div class=\"cp-chunk-filters\"><label class=\"cp-field\"><span>Topic</span><select name=\"chunk_topic_id\"></select></label><label class=\"cp-field\"><span>Ready source</span><select name=\"chunk_source_id\"></select></label></div><div class=\"cp-choice-grid\" data-choice-list=\"source_chunk_ids\"></div><p class=\"cp-empty-copy\" data-choice-empty>Choose a topic and source to load current evidence chunks.</p></div><div data-scope=\"wiki_page_id\" hidden><div class=\"cp-choice-grid\" data-choice-list=\"wiki_page_id\">");
    var first_wiki = true;
    for (wiki_pages) |item| {
        try renderChoice(req, w, "radio", "wiki_page_id", item.id, item.title, "Compiled from cited evidence", first_wiki);
        first_wiki = false;
    }
    if (first_wiki) try w.writeAll("<div class=\"cp-choice-empty\"><strong>No Wiki page is available</strong><span>Compile a cited article before using this scope.</span><a href=\"/wiki\">Open Wiki</a></div>");
    try w.writeAll("</div></div><p class=\"cp-scope-effective\" data-scope-effective role=\"status\">Enrollment · 0 selected</p></div></section><section class=\"cp-flash-step\"><header><span>3</span><div><h3>Create draft</h3><p>Name the draft if useful and choose a concise review size.</p></div></header><label class=\"cp-field\"><span>Draft title <small>Optional</small></span><input name=\"deck_title\" maxlength=\"1000\"></label><fieldset class=\"cp-count-choices\"><legend>Number of cards</legend>");
    const limits = [_]usize{ 5, 10, 15, 20 };
    for (limits) |limit| try w.print("<label><input type=\"radio\" name=\"limit_choice\" value=\"{d}\"{s}><span>{d}</span></label>", .{ limit, if (limit == 10) " checked" else "", limit });
    try w.writeAll("<label><input type=\"radio\" name=\"limit_choice\" value=\"custom\"><span>Custom</span></label><label class=\"cp-custom-count\" hidden><span class=\"sr-only\">Custom card count</span><input name=\"custom_limit\" type=\"number\" min=\"1\" max=\"20\" value=\"10\"></label></fieldset><details class=\"cp-flash-advanced\"><summary>Advanced</summary><label class=\"cp-check-row\"><input type=\"checkbox\" name=\"regenerate\"><span>Create a linked successor draft<small>Use this only when you intentionally want to supersede a matching draft. The earlier draft remains in history.</small></span></label></details><div class=\"cp-flash-submit\"><button class=\"cp-btn cp-btn-primary\" type=\"submit\">Generate flashcards</button><p>Review the generated cards before adding them to practice.</p></div><div class=\"cp-flash-generation\" data-flash-generation hidden role=\"status\" aria-live=\"polite\"><span class=\"cp-spinner\" aria-hidden=\"true\"></span><div><strong>Generating flashcards</strong><span>Reading the selected evidence and preparing your review draft.</span></div><span class=\"cp-generation-track\" aria-hidden=\"true\"><i></i></span></div></section></fieldset></form><p data-flash-create-status aria-live=\"polite\"></p>");
    if (demo) try w.writeAll("<p class=\"cp-demo-rating-note\">Synthetic demo fixture · configure the request freely. Previewing it does not create or save a draft.</p>");
    try w.writeAll("</section>");
}

fn renderChoice(req: mer.Request, w: *std.Io.Writer, kind: []const u8, name: []const u8, value: []const u8, title: []const u8, detail: []const u8, checked: bool) !void {
    try w.print("<label class=\"cp-choice-row\"><input type=\"{s}\" name=\"{s}\" value=\"{s}\"{s}><span class=\"cp-choice-check\" aria-hidden=\"true\">✓</span><span><strong>{s}</strong><small>{s}</small></span></label>", .{ kind, name, lib.ui.escapeSafe(req.allocator, value), if (checked) " checked" else "", lib.ui.escapeSafe(req.allocator, title), lib.ui.escapeSafe(req.allocator, detail) });
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
    try w.print("<section class=\"cp-draft-decks surface\" aria-labelledby=\"draft-decks-title\" data-draft-queue><header class=\"cp-review-queue-head\"><span class=\"cp-review-pending-icon\">{s}</span><div><p class=\"eyebrow\">Pending review</p><h2 id=\"draft-decks-title\">Review generated flashcards</h2><p>Check each draft, then publish the cards you want to practise.</p></div></header><div class=\"cp-draft-list\" data-draft-list>", .{ICON_CLOCK});
    var draft_count: usize = 0;
    for (decks) |deck| if (std.mem.eql(u8, deck.lifecycle, "draft")) {
        draft_count += 1;
        const updated = lib.time.formatRelative(req.allocator, deck.updated_at, lib.time.nowSecs()) catch "—";
        try w.print("<article data-draft-id=\"{s}\" data-draft-revision=\"{d}\"><span class=\"cp-review-pending-icon cp-review-pending-icon-small\">{s}</span><div><strong>{s}</strong><span>{d} cards · updated {s}</span></div><div class=\"cp-draft-actions\"><a class=\"cp-btn cp-btn-ghost\" href=\"/flashcards/drafts/{s}\">Review cards</a><button class=\"cp-icon-button cp-draft-delete\" type=\"button\" data-delete-draft aria-label=\"Delete {s} from the review queue\">{s}</button></div></article>", .{ lib.ui.escapeSafe(req.allocator, deck.id), deck.revision, ICON_CLOCK, lib.ui.escapeSafe(req.allocator, deck.title), deck.card_count, lib.ui.escapeSafe(req.allocator, updated), lib.ui.escapeSafe(req.allocator, deck.id), lib.ui.escapeSafe(req.allocator, deck.title), ICON_TRASH });
    };
    if (draft_count == 0) try w.writeAll("<p class=\"cp-empty-copy\" data-draft-empty>No flashcards are waiting for review.</p>");
    try w.writeAll("</div><p class=\"cp-draft-queue-status\" data-draft-queue-status aria-live=\"polite\"></p></section>");
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
