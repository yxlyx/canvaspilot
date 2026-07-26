const std = @import("std");
const mer = @import("mer");
const lib = @import("lib");

pub const meta: mer.Meta = .{ .title = "Review flashcard draft", .description = "Review and publish an evidence-backed flashcard draft." };

fn uuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, i| if (i == 8 or i == 13 or i == 18 or i == 23) {
        if (c != '-') return false;
    } else if (!std.ascii.isHex(c)) return false;
    return true;
}

fn join(allocator: std.mem.Allocator, values: []const []const u8) []const u8 {
    return std.mem.join(allocator, ", ", values) catch "";
}

fn scopeLabel(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "enrollment")) return "Module";
    if (std.mem.eql(u8, scope, "topics")) return "Curriculum topics";
    if (std.mem.eql(u8, scope, "sources")) return "Selected sources";
    if (std.mem.eql(u8, scope, "source_chunks")) return "Selected excerpts";
    if (std.mem.eql(u8, scope, "wiki_page")) return "Wiki article";
    return "Workspace evidence";
}

fn generationLabel(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "evidence_first")) return "Evidence-first generation";
    if (std.mem.eql(u8, provider, "local_fallback")) return "Local evidence fallback";
    return provider;
}

fn revisionActionLabel(action: []const u8) []const u8 {
    if (std.mem.eql(u8, action, "generated")) return "Draft created";
    if (std.mem.eql(u8, action, "regenerated")) return "Draft regenerated";
    if (std.mem.eql(u8, action, "updated")) return "Cards updated";
    if (std.mem.eql(u8, action, "published")) return "Deck published";
    if (std.mem.eql(u8, action, "archived")) return "Draft archived";
    return "Draft changed";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (needle, 0..) |expected, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(expected)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn isLowSignalCard(question: []const u8, answer: []const u8) bool {
    const terms = [_][]const u8{ "source header", "cover page", "document title", "course code", "module code", "which institution", "which university", "prepared by", "academic year" };
    for (terms) |term| if (containsIgnoreCase(question, term)) return true;
    const asks_metadata = containsIgnoreCase(question, "what") or containsIgnoreCase(question, "which");
    if (asks_metadata and (containsIgnoreCase(question, "institution") or containsIgnoreCase(question, "university") or containsIgnoreCase(question, "department") or containsIgnoreCase(question, "faculty"))) return true;
    return std.mem.count(u8, answer, " ") > 95;
}

test "legacy metadata cards require rewriting" {
    try std.testing.expect(isLowSignalCard("What institution appears in this material?", "A university header"));
    try std.testing.expect(!isLowSignalCard("Why do immutable values preserve history?", "Updates create new values."));
}

test "draft metadata uses learner-facing labels" {
    try std.testing.expectEqualStrings("Selected excerpts", scopeLabel("source_chunks"));
    try std.testing.expectEqualStrings("Evidence-first generation", generationLabel("evidence_first"));
    try std.testing.expectEqualStrings("Draft created", revisionActionLabel("generated"));
}

pub fn render(req: mer.Request) mer.Response {
    if (lib.m3.access(req) == .login) return mer.redirect("/login", .see_other);
    const id = req.param("deck_id") orelse return mer.badRequest("missing deck identifier");
    if (!uuid(id)) return mer.badRequest("invalid deck identifier");
    if (lib.m3.isExplicitDemo(req)) return mer.badRequest("draft review is read-only in demo mode");
    const token = lib.session.fromRequest(req).token;
    const deck_result = lib.backend.getFlashcardDraft(req.allocator, token, id);
    const deck = if (deck_result.value) |parsed| parsed.value else {
        if (deck_result.status == 404) return .{ .status = .not_found, .content_type = .html, .body = "<h1>Draft not found</h1>" };
        return lib.m3.liveError(req, "Flashcard draft", deck_result.status);
    };
    const history_result = lib.backend.listFlashcardDraftRevisions(req.allocator, token, id);
    const history = if (history_result.value) |parsed| parsed.value else return lib.m3.liveError(req, "Draft history", history_result.status);
    return renderReview(req, deck, history);
}

fn renderReview(req: mer.Request, deck: lib.types.FlashcardDeckResponse, history: []const lib.types.FlashcardRevisionResponse) mer.Response {
    var buf = lib.ui.buildHtml(req.allocator);
    const w = &buf.writer;
    const editable = std.mem.eql(u8, deck.lifecycle, "draft");
    const immutable = std.mem.eql(u8, deck.lifecycle, "approved");
    var active: usize = 0;
    var approved: usize = 0;
    var unsupported: usize = 0;
    var low_signal: usize = 0;
    for (deck.cards) |card| if (!std.mem.eql(u8, card.state, "discarded")) {
        active += 1;
        if (card.approved) approved += 1;
        if (!card.manual_note and (card.source_id == null or (card.source_chunk_id == null and card.wiki_page_id == null))) unsupported += 1;
        if (isLowSignalCard(card.question, card.answer)) low_signal += 1;
    };
    const publishable = editable and active > 0 and approved == active and unsupported == 0 and low_signal == 0;
    const scope_kind = objectString(deck.scope_snapshot, "kind") orelse deck.generation_scope;
    const provider = objectString(deck.generator_snapshot, "provider") orelse "Provider";
    const model = objectString(deck.generator_snapshot, "model") orelse "default model";
    const evidence_count = objectArrayLength(deck.scope_snapshot, "ordered_provenance");
    const source_count = objectArrayLength(deck.scope_snapshot, "source_ids") orelse deck.source_ids.len;
    const evidence_summary = if (evidence_count) |count| std.fmt.allocPrint(req.allocator, "{d} evidence passage{s}", .{ count, if (count == 1) "" else "s" }) catch "Evidence count unavailable" else "Evidence count unavailable";
    w.print("<div class=\"cp-draft-review\" data-draft-review data-deck-id=\"{s}\" data-revision=\"{d}\" data-lifecycle=\"{s}\"><a class=\"cp-back-link\" href=\"/flashcards\">← Flashcard workspace</a><header class=\"cp-page-header\"><div><p class=\"cp-page-kicker\">{s} · revision {d}</p><h1 class=\"cp-page-title\">Review draft</h1><p class=\"cp-page-sub\">Check each prompt against its evidence, then approve the cards you want to study.</p></div></header><div data-draft-status role=\"status\" aria-live=\"polite\"></div>", .{ deck.id, deck.revision, lib.ui.escapeSafe(req.allocator, deck.lifecycle), if (editable) "Draft" else "Approved", deck.revision }) catch return mer.internalError("draft render failed");
    if (immutable) w.print("<section class=\"cp-status-banner cp-status-info\"><strong>Approved snapshot — immutable.</strong> <a class=\"cp-btn cp-btn-primary\" href=\"/flashcards?deck={s}#cp-flash-review\">Start studying</a></section>", .{deck.id}) catch return mer.internalError("draft render failed");
    w.print("<section class=\"cp-draft-meta surface\"><form data-deck-form><label class=\"cp-field\"><span>Deck title</span><input name=\"title\" maxlength=\"1000\" value=\"{s}\"{s}></label><button class=\"cp-btn cp-btn-ghost\" type=\"submit\"{s}>Save title</button></form><dl class=\"cp-provenance\"><div><dt>Source scope</dt><dd><strong>{s}</strong><span>{d} source{s} · {s}</span></dd></div><div><dt>Generation</dt><dd><strong>{s}</strong><span>{s}</span></dd></div><div><dt>Draft lineage</dt><dd><strong>{s}</strong><span>Evidence-first generation</span></dd></div></dl></section>", .{ lib.ui.escapeSafe(req.allocator, deck.title), if (editable) "" else " disabled", if (editable) "" else " disabled", scopeLabel(scope_kind), source_count, if (source_count == 1) "" else "s", lib.ui.escapeSafe(req.allocator, evidence_summary), lib.ui.escapeSafe(req.allocator, generationLabel(provider)), lib.ui.escapeSafe(req.allocator, generationLabel(model)), if (deck.predecessor_id) |_| "Regenerated draft" else "First generation" }) catch return mer.internalError("draft render failed");
    w.writeAll("<section><div class=\"cp-section-heading-row\"><div><p class=\"eyebrow\">2 · Review evidence and content</p><h2>Cards</h2></div>") catch return mer.internalError("draft render failed");
    if (editable) w.writeAll("<button class=\"cp-btn cp-btn-ghost\" type=\"button\" data-add-card>Add card</button>") catch return mer.internalError("draft render failed");
    w.writeAll("</div><ol class=\"cp-draft-cards\" data-card-list>") catch return mer.internalError("draft render failed");
    for (deck.cards) |card| renderCard(req, w, card, deck.scope_snapshot, editable) catch return mer.internalError("draft render failed");
    w.writeAll("</ol></section>") catch return mer.internalError("draft render failed");
    if (editable) {
        w.print("<section class=\"cp-publish-panel surface\"><div><p class=\"eyebrow\">3 · Publish</p><h2>Approve and publish</h2><p>{d} active · {d} approved · {d} need attention</p>", .{ active, approved, unsupported + low_signal }) catch return mer.internalError("draft render failed");
        if (active == 0) w.writeAll("<p role=\"alert\">Publish is disabled because the deck has no active cards.</p>") catch return mer.internalError("draft render failed");
        if (approved != active) w.writeAll("<p role=\"alert\">Publish is disabled until every active card is approved.</p>") catch return mer.internalError("draft render failed");
        if (unsupported > 0) w.writeAll("<p role=\"alert\">Publish is disabled while a card lacks evidence or a personal-note label.</p>") catch return mer.internalError("draft render failed");
        if (low_signal > 0) w.writeAll("<p role=\"alert\">Publish is disabled until low-signal document metadata is rewritten or discarded.</p>") catch return mer.internalError("draft render failed");
        w.writeAll("</div><div class=\"cp-action-row\"><button class=\"cp-btn cp-btn-ghost\" type=\"button\" data-approve-selected>Approve selected</button><button class=\"cp-btn cp-btn-ghost\" type=\"button\" data-approve-all>Approve all supported</button><button class=\"cp-btn cp-btn-primary\" type=\"button\" data-publish") catch return mer.internalError("draft render failed");
        if (!publishable) w.writeAll(" disabled") catch return mer.internalError("draft render failed");
        w.writeAll(">Publish approved snapshot</button><button class=\"cp-btn cp-btn-danger\" type=\"button\" data-archive>Archive draft</button></div></section>") catch return mer.internalError("draft render failed");
    } else if (immutable) w.writeAll("<section class=\"cp-publish-panel surface\"><p>Retiring removes this immutable approved deck from study without rewriting it.</p><button class=\"cp-btn cp-btn-danger\" type=\"button\" data-retire>Retire approved deck</button></section>") catch return mer.internalError("draft render failed");
    w.writeAll("<details class=\"cp-draft-history surface\"><summary>Revision history and discarded-card audit</summary><ol>") catch return mer.internalError("draft render failed");
    for (history) |item| {
        const when = lib.time.formatRelative(req.allocator, item.created_at, lib.time.nowSecs()) catch "—";
        const exact = lib.time.formatAbsolute(req.allocator, item.created_at) catch "—";
        w.print("<li><strong>Revision {d} · {s}</strong><time datetime=\"{s}\" title=\"{s}\">{s}</time></li>", .{ item.revision, revisionActionLabel(item.action), lib.ui.escapeSafe(req.allocator, item.created_at), lib.ui.escapeSafe(req.allocator, exact), lib.ui.escapeSafe(req.allocator, when) }) catch return mer.internalError("draft render failed");
    }
    w.writeAll("</ol></details></div>") catch return mer.internalError("draft render failed");
    return lib.m3.privateForSession(req, lib.ui.htmlResponse(&buf));
}

fn objectString(item: std.json.Value, key: []const u8) ?[]const u8 {
    if (item != .object) return null;
    const value = item.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn objectArrayLength(item: std.json.Value, key: []const u8) ?usize {
    if (item != .object) return null;
    const value = item.object.get(key) orelse return null;
    return if (value == .array) value.array.items.len else null;
}

fn renderCitationSelector(req: mer.Request, w: *std.Io.Writer, card: lib.types.FlashcardResponse, scope: std.json.Value, disabled: []const u8) !void {
    try w.print("<label class=\"cp-field\"><span>Evidence citation</span><select name=\"citation_choice\"{s}><option value=\"\">Select current evidence</option>", .{disabled});
    if (scope == .object) if (scope.object.get("ordered_provenance")) |items| if (items == .array) {
        for (items.array.items) |item| {
            const source_id = objectString(item, "source_id") orelse continue;
            const chunk_id = objectString(item, "source_chunk_id") orelse continue;
            const wiki_id = objectString(item, "wiki_page_id") orelse "";
            if (!uuid(source_id) or !uuid(chunk_id) or (wiki_id.len > 0 and !uuid(wiki_id))) continue;
            const selected = card.source_id != null and card.source_chunk_id != null and
                std.mem.eql(u8, card.source_id.?, source_id) and
                std.mem.eql(u8, card.source_chunk_id.?, chunk_id) and
                ((card.wiki_page_id == null and wiki_id.len == 0) or
                    (card.wiki_page_id != null and std.mem.eql(u8, card.wiki_page_id.?, wiki_id)));
            const title = objectString(item, "source_title") orelse "Source";
            const citation = objectString(item, "citation_ref") orelse "Evidence";
            const location = objectString(item, "location_label") orelse "";
            try w.print("<option value=\"{s}|{s}|{s}\"{s}>{s} · {s}{s}{s}</option>", .{ lib.ui.escapeSafe(req.allocator, source_id), lib.ui.escapeSafe(req.allocator, chunk_id), lib.ui.escapeSafe(req.allocator, wiki_id), if (selected) " selected" else "", lib.ui.escapeSafe(req.allocator, title), lib.ui.escapeSafe(req.allocator, citation), if (location.len > 0) " · " else "", lib.ui.escapeSafe(req.allocator, location) });
        }
    };
    try w.writeAll("</select><small>Only evidence captured in this draft's immutable scope is available.</small></label>");
}

fn citationExcerpt(card: lib.types.FlashcardResponse) []const u8 {
    if (card.citations.len == 0) return "No excerpt captured";
    return objectString(card.citations[0], "excerpt") orelse "No excerpt captured";
}

fn renderCard(req: mer.Request, w: *std.Io.Writer, card: lib.types.FlashcardResponse, scope: std.json.Value, editable: bool) !void {
    const discarded = std.mem.eql(u8, card.state, "discarded");
    const low_signal = isLowSignalCard(card.question, card.answer);
    const disabled = if (editable and !discarded) "" else " disabled";
    try w.print("<li class=\"cp-draft-card surface{s}\" data-card-id=\"{s}\" data-approved=\"{s}\" data-discarded=\"{s}\"><header><span>Card {d}</span><span class=\"status-pill status-{s}\">{s}</span>{s}</header>", .{ if (discarded) " is-discarded" else "", card.id, if (card.approved) "true" else "false", if (discarded) "true" else "false", card.order_index + 1, if (discarded) "neutral" else if (low_signal) "warn" else if (card.approved) "ok" else "info", if (discarded) "Discarded" else if (low_signal) "Needs rewrite" else if (card.approved) "Approved" else "Needs approval", if (editable and !discarded and !low_signal) "<label><input type=\"checkbox\" data-card-select> Select card</label>" else "" });
    if (low_signal and !discarded) try w.writeAll("<div class=\"notice notice-warn\" role=\"alert\"><strong>This card tests document metadata</strong> <span>Rewrite it around a useful course concept or discard it before publishing.</span></div>");
    try w.print("<form data-card-form><label class=\"cp-field\"><span>Prompt</span><textarea name=\"question\" maxlength=\"10000\"{s}>{s}</textarea></label><label class=\"cp-field\"><span>Answer</span><textarea name=\"answer\" maxlength=\"20000\"{s}>{s}</textarea></label>", .{ disabled, lib.ui.escapeSafe(req.allocator, card.question), disabled, lib.ui.escapeSafe(req.allocator, card.answer) });
    try w.print("<div class=\"cp-card-fields\"><label class=\"cp-field\"><span>Tags</span><input name=\"tags\" value=\"{s}\"{s}></label><label class=\"cp-field\"><span>Topic links</span><input name=\"topic_ids\" value=\"{s}\"{s}><small>Optional connections to topics already in your Wiki.</small></label></div><fieldset class=\"cp-evidence-choice\"><legend>Strict evidence selection</legend><label><input type=\"radio\" name=\"evidence_kind\" value=\"citation\"{s}{s}> Evidence-backed citation</label><label><input type=\"radio\" name=\"evidence_kind\" value=\"personal\"{s}{s}> Clearly labelled personal note</label>", .{ lib.ui.escapeSafe(req.allocator, join(req.allocator, card.tags)), disabled, lib.ui.escapeSafe(req.allocator, join(req.allocator, card.topic_ids)), disabled, if (!card.manual_note) " checked" else "", disabled, if (card.manual_note) " checked" else "", disabled });
    try renderCitationSelector(req, w, card, scope, disabled);
    try w.print("<article class=\"cp-citation-detail\"><p class=\"eyebrow\">Concept · {s}</p><strong>{s}</strong><span>{s}</span><blockquote>{s}</blockquote><details><summary>Evidence identifiers</summary><span>Source <code>{s}</code></span><span>Current chunk <code>{s}</code></span><span>Wiki page <code>{s}</code></span></details><a href=\"/sources?source={s}\">Open exact source context →</a></article></fieldset>", .{ lib.ui.escapeSafe(req.allocator, card.topic_tag), lib.ui.escapeSafe(req.allocator, card.source_title), lib.ui.escapeSafe(req.allocator, card.location_label), lib.ui.escapeSafe(req.allocator, citationExcerpt(card)), lib.ui.escapeSafe(req.allocator, card.source_id orelse "None"), lib.ui.escapeSafe(req.allocator, card.source_chunk_id orelse "None"), lib.ui.escapeSafe(req.allocator, card.wiki_page_id orelse "None"), lib.ui.escapeSafe(req.allocator, card.source_id orelse "") });
    if (editable and !discarded) try w.writeAll("<button class=\"cp-btn cp-btn-ghost\" type=\"submit\">Save card</button>");
    try w.writeAll("</form><footer class=\"cp-action-row\">");
    if (editable) if (discarded) try w.writeAll("<button type=\"button\" class=\"cp-btn cp-btn-ghost\" data-restore>Restore</button>") else {
        try w.writeAll("<button type=\"button\" class=\"cp-btn cp-btn-ghost\" data-move=\"up\" aria-label=\"Move card up\">↑ Up</button><button type=\"button\" class=\"cp-btn cp-btn-ghost\" data-move=\"down\" aria-label=\"Move card down\">↓ Down</button><button type=\"button\" class=\"cp-btn cp-btn-ghost\" data-approve");
        if (low_signal) try w.writeAll(" disabled title=\"Rewrite this card before approving\"");
        try w.writeAll(">Approve</button><label class=\"cp-rejection-reason\"><span>Why reject?</span><select data-rejection-reason><option value=\"\">Choose a reason</option><option value=\"too_generic\">Too generic</option><option value=\"ambiguous_answer\">Ambiguous answer</option><option value=\"wrong_concept\">Wrong concept</option><option value=\"poor_evidence\">Poor evidence</option><option value=\"duplicate\">Duplicate</option><option value=\"other\">Other</option></select></label><button type=\"button\" class=\"cp-btn cp-btn-danger\" data-discard>Discard</button>");
    };
    try w.writeAll("</footer></li>");
}
