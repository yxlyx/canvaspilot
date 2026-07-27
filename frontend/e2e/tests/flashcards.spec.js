const fs = require("node:fs");
const path = require("node:path");
const { expect, test } = require("@playwright/test");

async function loadScript(page, body) {
  await page.goto("/login");
  await page.setContent(body);
  await page.addScriptTag({ url: "/app.js" });
}

test("draft review summarizes generation details instead of printing snapshot JSON", async () => {
  const root = path.resolve(__dirname, "../..");
  const pageSource = fs.readFileSync(path.join(root, "app/flashcards/drafts/[deck_id].zig"), "utf8");
  const styles = fs.readFileSync(path.join(root, "app/_styles.css"), "utf8");

  expect(pageSource).not.toContain("valueJson");
  expect(pageSource).toContain("evidence passage");
  expect(pageSource).toContain("generator_snapshot, \"provider\"");
  expect(styles).toContain(".cp-provenance { display: grid");
  expect(styles).toContain(".cp-card-editor {");
  expect(pageSource).toContain("cp-card-disclosure");
  expect(pageSource).toContain("cp-history-ledger");
  expect(pageSource).not.toContain("card.order_index + 1");
  expect(pageSource).toContain('std.mem.eql(u8, action, "publish")');
  expect(pageSource).toContain('std.mem.eql(u8, action, "retired")');
  expect(pageSource).toContain("canPublish(editable, active, approved, unsupported)");
  expect(pageSource).not.toContain("approved == active and unsupported == 0 and low_signal");
  expect(styles).toContain(".cp-citation-detail > a { width: fit-content; min-height: 44px;");
});

test("flashcard workspace renders only the active minimalist view", async ({ page }) => {
  await page.goto("/flashcards?mock=1");
  await expect(page.getByRole("heading", { name: "Evidence-backed review" })).toBeVisible();
  await expect(page.locator("#cp-flash-review")).toBeVisible();
  await expect(page.locator("[data-flash-create]")).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Study", exact: true })).toHaveAttribute("aria-current", "page");

  await page.goto("/flashcards?mock=1&view=create");
  await expect(page.getByRole("heading", { name: "Create flashcards" })).toBeVisible();
  await expect(page.locator("[data-flash-create]")).toBeVisible();
  await expect(page.locator("#cp-flash-review")).toHaveCount(0);

  await page.goto("/flashcards?mock=1&view=drafts");
  await expect(page.getByRole("heading", { name: "Drafts & published decks" })).toBeVisible();
  await expect(page.locator(".cp-deck-history")).toBeVisible();
  await expect(page.locator("#cp-flash-review, [data-flash-create]")).toHaveCount(0);
});

test("published history exposes both study and immutable record actions", () => {
  const root = path.resolve(__dirname, "../..");
  const pageSource = fs.readFileSync(path.join(root, "app/flashcards.zig"), "utf8");

  expect(pageSource).toContain(">Study deck</a>");
  expect(pageSource).toContain(">View record</a>");
  expect(pageSource).toContain('href=\\\"/flashcards/drafts/{s}\\\"');
});

test("creation prefers an available stable scope and disables inactive controls", () => {
  const root = path.resolve(__dirname, "../..");
  const pageSource = fs.readFileSync(path.join(root, "app/flashcards.zig"), "utf8");
  const script = fs.readFileSync(path.join(root, "public/app.js"), "utf8");

  expect(pageSource).toContain('if (has_enrollment) "enrollment_id" else if (has_source) "source_ids"');
  expect(pageSource).toContain('" selected"');
  expect(pageSource).toContain('data-scope=\\\"enrollment_id topic_ids source_chunk_ids\\\"');
  expect(script).toContain("control.disabled = !active");
  expect(script).toContain('control.name === scope || control.name === "enrollment_id"');
});

test("draft review remains readable without horizontal overflow on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await loadScript(page, `<main class="cp-draft-review"><section class="cp-draft-meta surface"><form><label class="cp-field"><span>Deck title</span><input value="Data structures review"></label><button class="cp-btn">Save title</button></form><dl class="cp-provenance"><div><dt>Source scope</dt><dd><strong>source_chunks</strong><span>1 source · 4 evidence passages</span></dd></div><div><dt>Generation</dt><dd><strong>chatgpt</strong><span>study-model</span></dd></div><div><dt>Draft record</dt><dd><code>123456789abc…</code></dd></div></dl></section><ol class="cp-draft-cards"><li class="cp-draft-card surface"><form><label class="cp-field"><span>Prompt</span><textarea>How do stable secondary keys affect ordering?</textarea></label><label class="cp-field"><span>Answer</span><textarea>Stable secondary keys make result ordering deterministic.</textarea></label><fieldset class="cp-evidence-choice"><legend>Strict evidence selection</legend><label><input type="radio"> Evidence-backed citation</label><article class="cp-citation-detail"><blockquote>Stable secondary keys make result ordering deterministic when primary values are equal.</blockquote></article></fieldset></form></li></ol></main>`);
  await page.addStyleTag({ content: fs.readFileSync(path.resolve(__dirname, "../../app/_styles.css"), "utf8") });

  const inputSize = await page.locator(".cp-field input").evaluate((node) => parseFloat(getComputedStyle(node).fontSize));
  const columns = await page.locator(".cp-provenance").evaluate((node) => getComputedStyle(node).gridTemplateColumns.split(" ").length);
  const overflow = await page.locator(".cp-draft-review").evaluate((node) => node.scrollWidth - node.clientWidth);

  expect(inputSize).toBeGreaterThanOrEqual(14);
  expect(columns).toBe(1);
  expect(overflow).toBeLessThanOrEqual(1);
});

test("rating retry keeps the revealed card and stable interaction key until save", async ({ page }) => {
  const requests = [];
  await page.route("**/api/flashcards", async (route) => {
    const body = route.request().postDataJSON();
    requests.push(body);
    if (requests.length === 1) return route.fulfill({ status: 503, json: { detail: "offline" } });
    return route.fulfill({ status: 200, json: { is_correct: true, rating: "Good" } });
  });
  await loadScript(page, `<main id="cp-flash-review"><article id="cp-flashcard"><b id="cp-card-number">1</b><h2 id="cp-card-question"></h2><details id="cp-card-details"><summary id="cp-reveal-card">Reveal answer</summary><div id="cp-card-answer"><span id="cp-card-answer-text"></span><span id="cp-card-source"></span><span id="cp-card-page"></span><a id="cp-card-source-link"></a><a id="cp-card-context-link"></a></div><div id="cp-rating-panel"><div><form action="/api/flashcards" data-flash-rate><input name="card_id"><input name="deck_id" value="123e4567-e89b-12d3-a456-426614174000"><input name="rating" value="Good"><button type="submit">Good</button></form><form action="/api/flashcards" data-flash-rate><input name="card_id"><input name="deck_id" value="123e4567-e89b-12d3-a456-426614174000"><input name="rating" value="Easy"><button type="submit">Easy</button></form></div></div></details></article><div id="cp-review-hint"></div><div id="cp-flash-data"><span data-card-id="223e4567-e89b-12d3-a456-426614174000" data-question="Stable prompt" data-answer="Answer"></span></div><b id="cp-reviewed-count">0</b><b id="cp-evidence-reviewed">0</b><b id="cp-evidence-recall">—</b><i id="cp-review-bar"></i></main>`);
  await page.getByText("Reveal answer", { exact: true }).click();
  await page.getByRole("button", { name: "Good" }).click();
  await expect(page.getByText(/same interaction key/i)).toBeVisible();
  await expect(page.locator('#cp-card-details')).toHaveAttribute("open", "");
  await expect(page.locator("#cp-reviewed-count")).toHaveText("0");
  await page.getByRole("button", { name: "Easy" }).click();
  await expect(page.getByText(/retry the same Good rating/i)).toBeVisible();
  expect(requests).toHaveLength(1);
  await page.getByRole("button", { name: "Good" }).click();
  await expect(page.locator("#cp-reviewed-count")).toHaveText("1");
  expect(requests.map((item) => item.idempotency_key)).toEqual([requests[0].idempotency_key, requests[0].idempotency_key]);
  expect(requests[0].payload).toEqual({ rating: "Good", answer_text: "" });
});

test("unknown rating outcome survives reload with the same interaction key", async ({ page }) => {
  const deckId = "123e4567-e89b-12d3-a456-426614174000";
  const cardId = "223e4567-e89b-12d3-a456-426614174000";
  const stableKey = "rating-stable-reload-key";
  const requests = [];
  await page.route("**/api/flashcards", async (route) => {
    requests.push(route.request().postDataJSON());
    return route.fulfill({ status: 200, json: { is_correct: true, confidence: 3 } });
  });
  await page.goto("/login");
  await page.evaluate(({ deckId, cardId, stableKey }) => {
    sessionStorage.setItem("flashcard-pending-rating-" + deckId, JSON.stringify({ cardId, rating: "Good", key: stableKey }));
    sessionStorage.setItem("flashcard-current-" + deckId, cardId);
  }, { deckId, cardId, stableKey });
  await page.setContent(`<main id="cp-flash-review"><article id="cp-flashcard"><b id="cp-card-number">1</b><h2 id="cp-card-question"></h2><details id="cp-card-details"><summary id="cp-reveal-card">Reveal answer</summary><div id="cp-card-answer"><span id="cp-card-answer-text"></span><span id="cp-card-source"></span><span id="cp-card-page"></span><a id="cp-card-source-link"></a><a id="cp-card-context-link"></a></div><div id="cp-rating-panel"><form data-flash-rate><input name="card_id"><input name="deck_id" value="${deckId}"><input name="rating" value="Good"><button type="submit">Good</button></form></div></details></article><div id="cp-review-hint"></div><div id="cp-flash-data"><span data-card-id="${cardId}" data-question="Stable prompt" data-answer="Answer"></span></div><b id="cp-reviewed-count">0</b><b id="cp-evidence-reviewed">0</b><i id="cp-review-bar"></i></main>`);
  await page.addScriptTag({ url: "/app.js" });

  await expect(page.locator("#cp-card-details")).toHaveAttribute("open", "");
  await expect(page.getByText(/previous save outcome is unknown/i)).toBeVisible();
  await page.getByRole("button", { name: "Good" }).click();

  await expect.poll(() => requests.length).toBe(1);
  expect(requests[0].idempotency_key).toBe(stableKey);
  await expect.poll(() => page.evaluate((key) => sessionStorage.getItem(key), "flashcard-pending-rating-" + deckId)).toBeNull();
});

test("skip advances locally, persists the cursor, and records no rating", async ({ page }) => {
  await loadScript(page, `<main id="cp-flash-review"><article id="cp-flashcard"><b id="cp-card-number">1</b><h2 id="cp-card-question"></h2><details id="cp-card-details"><summary id="cp-reveal-card">Reveal answer</summary><div id="cp-card-answer"><span id="cp-card-answer-text"></span><span id="cp-card-source"></span><span id="cp-card-page"></span><a id="cp-card-source-link"></a><a id="cp-card-context-link"></a></div><div id="cp-rating-panel"><div></div></div></details></article><button id="cp-skip-card" type="button">Skip for now</button><div id="cp-review-hint"></div><div id="cp-flash-data"><span data-card-id="223e4567-e89b-12d3-a456-426614174000" data-question="First prompt" data-answer="First answer"></span><span data-card-id="323e4567-e89b-12d3-a456-426614174000" data-question="Second prompt" data-answer="Second answer"></span></div><form data-flash-rate><input name="deck_id" value="123e4567-e89b-12d3-a456-426614174000"></form><b id="cp-reviewed-count">0</b><b id="cp-evidence-reviewed">0</b><b id="cp-evidence-recalled">0</b><b id="cp-evidence-missed">0</b><b id="cp-evidence-confidence">—</b><b id="cp-evidence-skipped">0</b><i id="cp-review-bar"></i></main>`);
  await expect(page.locator("#cp-card-question")).toHaveText("First prompt");
  await page.getByRole("button", { name: "Skip for now" }).click();
  await expect(page.locator("#cp-card-question")).toHaveText("Second prompt");
  await expect(page.locator("#cp-evidence-skipped")).toHaveText("1");
  await expect.poll(() => page.evaluate(() => sessionStorage.getItem("flashcard-current-123e4567-e89b-12d3-a456-426614174000"))).toBe("323e4567-e89b-12d3-a456-426614174000");
  await page.keyboard.press("s");
  await expect(page.locator("#cp-card-question")).toHaveText("First prompt");
  await expect(page.locator("#cp-evidence-skipped")).toHaveText("2");
  await expect(page.locator("#cp-reviewed-count")).toHaveText("0");
});

test("draft conflict preserves fields and exposes explicit reload/reapply", async ({ page }) => {
  await page.route("**/api/flashcards", (route) => route.fulfill({ status: 409, json: { detail: "revision changed" } }));
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="4" data-lifecycle="draft"><div data-draft-status></div><form data-deck-form data-recovery-key="deck"><input name="title" value="Original"><button>Save title</button></form><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false"><form data-card-form data-recovery-key="card:223e4567-e89b-12d3-a456-426614174000"><textarea name="question">Prompt</textarea><textarea name="answer">Answer</textarea><input name="tags"><input name="topic_ids"><input type="radio" name="evidence_kind" value="personal" checked><select name="citation_choice"><option value="">No citation</option></select><button>Save card</button></form></li></ol></main>`);
  await page.locator('[name="title"]').fill("Unsaved local title");
  await page.getByRole("button", { name: "Save title" }).click();
  await expect(page.getByText(/changed elsewhere/i)).toBeVisible();
  await expect(page.locator('[name="title"]')).toHaveValue("Unsaved local title");
  const reload = page.getByRole("button", { name: /reload latest and reapply/i });
  await expect(reload).toBeVisible();
  await reload.click();
  await page.waitForLoadState();
  const recovery = await page.evaluate(() => JSON.parse(sessionStorage.getItem("flashcard-draft-reapply-123e4567-e89b-12d3-a456-426614174000")));
  expect(recovery.deck.title).toBe("Unsaved local title");
});

test("recovered edits survive restoring a card discarded by another reviewer", async ({ page }) => {
  let requestBody;
  await page.route("**/api/flashcards", async (route) => {
    requestBody = route.request().postDataJSON();
    return route.fulfill({ status: 200, json: { revision: 6 } });
  });
  await page.goto("/login");
  await page.evaluate(() => sessionStorage.setItem("flashcard-draft-reapply-123e4567-e89b-12d3-a456-426614174000", JSON.stringify({
    "card:223e4567-e89b-12d3-a456-426614174000": { question: "Recovered prompt", answer: "Recovered answer" },
  })));
  await page.setContent(`<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="5" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="true"><form data-card-form data-recovery-key="card:223e4567-e89b-12d3-a456-426614174000"><textarea name="question" disabled>Server prompt</textarea><textarea name="answer" disabled>Server answer</textarea></form><button type="button" data-restore>Restore card</button></li></ol></main>`);
  await page.addScriptTag({ url: "/app.js" });

  await expect(page.locator('[name="question"]')).toHaveValue("Recovered prompt");
  await page.getByRole("button", { name: "Restore card" }).click();
  await expect.poll(() => requestBody && requestBody.action).toBe("restore");
  await page.waitForLoadState();
  const recovery = await page.evaluate(() => JSON.parse(sessionStorage.getItem("flashcard-draft-reapply-123e4567-e89b-12d3-a456-426614174000")));
  expect(recovery["card:223e4567-e89b-12d3-a456-426614174000"].question).toBe("Recovered prompt");
});

test("stale recovery data cannot block retiring an immutable deck", async ({ page }) => {
  const deckId = "123e4567-e89b-12d3-a456-426614174000";
  let requestBody;
  await page.route("**/api/flashcards", async (route) => {
    requestBody = route.request().postDataJSON();
    return route.fulfill({ status: 200, json: { revision: 8 } });
  });
  page.on("dialog", (dialog) => dialog.accept());
  await page.goto("/login");
  await page.evaluate((id) => sessionStorage.setItem("flashcard-draft-reapply-" + id, JSON.stringify({ deck: { title: "Stale title" } })), deckId);
  await page.setContent(`<main data-draft-review data-deck-id="${deckId}" data-revision="7" data-lifecycle="approved"><div data-draft-status></div><form data-deck-form data-recovery-key="deck"><input name="title" value="Published" disabled></form><button data-retire>Retire deck</button></main>`);
  await page.addScriptTag({ url: "/app.js" });

  await page.getByRole("button", { name: "Retire deck" }).click();

  await expect.poll(() => requestBody && requestBody.action).toBe("retire");
  await expect.poll(() => page.evaluate((id) => sessionStorage.getItem("flashcard-draft-reapply-" + id), deckId)).toBeNull();
});

test("draft review changes the selected snapshotted citation", async ({ page }) => {
  const requests = [];
  await page.route("**/api/flashcards", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, json: { revision: 5 } });
  });
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="4" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false"><form data-card-form><textarea name="question">Prompt</textarea><textarea name="answer">Answer</textarea><input name="tags"><input name="topic_ids"><input type="radio" name="evidence_kind" value="citation" checked><select name="citation_choice"><option value="323e4567-e89b-12d3-a456-426614174000|423e4567-e89b-12d3-a456-426614174000|">First citation</option><option value="523e4567-e89b-12d3-a456-426614174000|623e4567-e89b-12d3-a456-426614174000|723e4567-e89b-12d3-a456-426614174000">Updated citation</option></select><button>Save card</button></form></li></ol></main>`);
  await page.locator('[name="citation_choice"]').selectOption("523e4567-e89b-12d3-a456-426614174000|623e4567-e89b-12d3-a456-426614174000|723e4567-e89b-12d3-a456-426614174000");
  await page.getByRole("button", { name: "Save card" }).click();
  await expect.poll(() => requests.length).toBe(1);
  expect(requests[0].payload.citations).toEqual([{ source_id: "523e4567-e89b-12d3-a456-426614174000", source_chunk_id: "623e4567-e89b-12d3-a456-426614174000", wiki_page_id: "723e4567-e89b-12d3-a456-426614174000" }]);
});

test("approve, publish, and retire remain explicit draft lifecycle actions", async ({ page }) => {
  const requests = [];
  await page.route("**/api/flashcards", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, json: { revision: 6 } });
  });
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="5" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false" data-approvable="true"></li></ol><button data-approve-all>Approve all supported</button></main>`);
  await page.getByRole("button", { name: "Approve all supported" }).click();
  await expect.poll(() => requests.some((item) => item.action === "approve")).toBe(true);
  expect(requests.find((item) => item.action === "approve").payload.card_ids).toEqual(["223e4567-e89b-12d3-a456-426614174000"]);

  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="6" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list></ol><button data-publish>Publish approved snapshot</button></main>`);
  await page.getByRole("button", { name: "Publish approved snapshot" }).click();
  await expect.poll(() => requests.some((item) => item.action === "publish")).toBe(true);

  page.on("dialog", (dialog) => dialog.accept());
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="7" data-lifecycle="approved"><div data-draft-status></div><ol data-card-list></ol><button data-retire>Retire approved deck</button></main>`);
  await page.getByRole("button", { name: "Retire approved deck" }).click();
  await expect.poll(() => requests.some((item) => item.action === "retire")).toBe(true);
});

test("publish rejection preserves the draft and reports that nothing was saved", async ({ page }) => {
  await page.route("**/api/flashcards", (route) => route.fulfill({ status: 422, json: { detail: "unsupported card" } }));
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="6" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false" data-approvable="false"></li></ol><button data-publish>Publish deck</button></main>`);
  const before = page.url();

  await page.getByRole("button", { name: "Publish deck" }).click();

  await expect(page.locator("[data-draft-status]")).toContainText("change was not saved");
  expect(page.url()).toBe(before);
});

test("discard requires and submits a card quality reason", async ({ page }) => {
  let requestBody;
  await page.route("**/api/flashcards", async (route) => {
    requestBody = route.request().postDataJSON();
    return route.fulfill({ status: 200, json: { revision: 5 } });
  });
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="4" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false"><select data-rejection-reason><option value="">Choose a reason</option><option value="too_generic">Too generic</option></select><button type="button" data-discard>Discard</button></li></ol></main>`);
  await page.getByRole("button", { name: "Discard" }).click();
  await expect(page.locator("[data-draft-status]")).toContainText("Choose why this card is not useful");
  expect(requestBody).toBeUndefined();
  await page.locator("[data-rejection-reason]").selectOption("too_generic");
  await page.getByRole("button", { name: "Discard" }).click();
  await expect.poll(() => requestBody && requestBody.payload.rejection_reason).toBe("too_generic");
  expect(requestBody.payload.card_ids).toEqual(["223e4567-e89b-12d3-a456-426614174000"]);
});

test("reorder submits only active cards when discarded rows remain visible", async ({ page }) => {
  let requestBody;
  await page.route("**/api/flashcards", async (route) => {
    requestBody = route.request().postDataJSON();
    return route.fulfill({ status: 200, json: { revision: 6 } });
  });
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="5" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false"><button type="button" data-move="down">Move down</button></li><li data-card-id="323e4567-e89b-12d3-a456-426614174000" data-discarded="true"></li><li data-card-id="423e4567-e89b-12d3-a456-426614174000" data-discarded="false"></li></ol></main>`);

  await page.getByRole("button", { name: "Move down" }).click();

  await expect.poll(() => requestBody && requestBody.action).toBe("reorder");
  expect(requestBody.payload.card_ids).toEqual([
    "423e4567-e89b-12d3-a456-426614174000",
    "223e4567-e89b-12d3-a456-426614174000",
  ]);
});

test("generation links to provider settings when no answer provider is available", async ({ page }) => {
  await page.route("**/api/flashcards", async (route) => {
    const body = route.request().postDataJSON();
    if (body.action === "generate") return route.fulfill({ status: 409, json: { error: "provider_not_configured", detail: "Connect a provider" } });
    return route.fulfill({ status: 200, json: [] });
  });
  await loadScript(page, `<section data-flash-create><form><fieldset><input type="radio" name="scope_type" value="enrollment_id" checked><label data-scope="enrollment_id"><select name="enrollment_id"><option value="123e4567-e89b-12d3-a456-426614174000">Module</option></select></label><label data-scope="topic_ids"><select name="topic_ids" multiple></select></label><label data-scope="source_ids"><select name="source_ids" multiple></select></label><div data-scope="source_chunk_ids"><select name="chunk_topic_id"></select><select name="chunk_source_id"></select><select name="source_chunk_ids" multiple></select></div><label data-scope="wiki_page_id"><select name="wiki_page_id"></select></label><input name="deck_title"><input name="limit" value="10"><input type="checkbox" name="regenerate"><span data-scope-effective></span><button type="submit">Generate review draft</button></fieldset></form><p data-flash-create-status></p></section>`);

  await page.getByRole("button", { name: "Generate review draft" }).click();

  await expect(page.getByRole("link", { name: "Open provider settings" })).toHaveAttribute("href", "/settings/providers");
  await expect(page.locator("[data-flash-create-status]")).toContainText("scope selection is preserved");
});

test("expired generation session preserves scope and offers sign in", async ({ page }) => {
  await page.route("**/api/flashcards", async (route) => {
    const body = route.request().postDataJSON();
    if (body.action === "generate") return route.fulfill({ status: 401, json: { detail: "expired" } });
    return route.fulfill({ status: 200, json: [] });
  });
  await loadScript(page, `<section data-flash-create><form><fieldset><input type="radio" name="scope_type" value="source_ids" checked><label data-scope="enrollment_id topic_ids source_chunk_ids" hidden><select name="enrollment_id"></select></label><label data-scope="topic_ids" hidden><select name="topic_ids" multiple></select></label><label data-scope="source_ids"><select name="source_ids" multiple><option value="123e4567-e89b-12d3-a456-426614174000" selected>Ready source</option></select></label><div data-scope="source_chunk_ids" hidden><select name="chunk_topic_id"></select><select name="chunk_source_id"></select><select name="source_chunk_ids" multiple></select></div><label data-scope="wiki_page_id" hidden><select name="wiki_page_id"></select></label><input name="deck_title" value="Saved scope"><input name="limit" value="10"><input type="checkbox" name="regenerate"><span data-scope-effective></span><button type="submit">Create review draft</button></fieldset></form><p data-flash-create-status></p></section>`);

  await page.getByRole("button", { name: "Create review draft" }).click();

  await expect(page.getByRole("link", { name: /sign in, then return to create/i })).toHaveAttribute("href", "/login");
  const recovery = await page.evaluate(() => JSON.parse(sessionStorage.getItem("flashcard-create-recovery")));
  expect(recovery.scope_type).toBe("source_ids");
  expect(recovery.source_ids).toEqual(["123e4567-e89b-12d3-a456-426614174000"]);
  expect(recovery.deck_title).toBe("Saved scope");
});

test("recovered chunk scope refetches the saved topic and source before restoring chunks", async ({ page }) => {
  const enrollmentId = "123e4567-e89b-12d3-a456-426614174000";
  const topicId = "223e4567-e89b-12d3-a456-426614174000";
  const sourceId = "323e4567-e89b-12d3-a456-426614174000";
  const chunkId = "423e4567-e89b-12d3-a456-426614174000";
  const requests = [];
  await page.route("**/api/flashcards", async (route) => {
    const body = route.request().postDataJSON();
    requests.push(body);
    if (body.action === "topics") return route.fulfill({ status: 200, json: [{ id: topicId, title: "Saved topic", provenance: "catalog", archived: false }] });
    if (body.action === "candidates") return route.fulfill({ status: 200, json: [{ id: sourceId, title: "Saved source", eligible: true, state: "ready" }] });
    if (body.action === "chunks") return route.fulfill({ status: 200, json: [{ chunk_id: chunkId, citation: "Saved passage", excerpt: "Evidence" }] });
    return route.fulfill({ status: 200, json: [] });
  });
  await page.goto("/login");
  await page.evaluate((recovery) => sessionStorage.setItem("flashcard-create-recovery", JSON.stringify(recovery)), {
    scope_type: "source_chunk_ids",
    enrollment_id: enrollmentId,
    chunk_topic_id: topicId,
    chunk_source_id: sourceId,
    source_chunk_ids: [chunkId],
    limit: "10",
  });
  await page.setContent(`<section data-flash-create><form><fieldset><input type="radio" name="scope_type" value="enrollment_id" checked><input type="radio" name="scope_type" value="source_chunk_ids"><label data-scope="enrollment_id topic_ids source_chunk_ids"><select name="enrollment_id"><option value="${enrollmentId}">Module</option></select></label><label data-scope="topic_ids" hidden><select name="topic_ids" multiple></select></label><label data-scope="source_ids" hidden><select name="source_ids" multiple></select></label><div data-scope="source_chunk_ids" hidden><select name="chunk_topic_id"></select><select name="chunk_source_id"></select><select name="source_chunk_ids" multiple></select></div><label data-scope="wiki_page_id" hidden><select name="wiki_page_id"></select></label><input name="deck_title"><input name="limit" value="10"><input type="checkbox" name="regenerate"><span data-scope-effective></span><button type="submit">Create review draft</button></fieldset></form><p data-flash-create-status></p></section>`);
  await page.addScriptTag({ url: "/app.js" });

  await expect.poll(() => requests.some((item) => item.action === "chunks")).toBe(true);
  const chunks = requests.find((item) => item.action === "chunks");
  expect(chunks.payload).toEqual({ topic_id: topicId, source_id: sourceId });
  await expect(page.locator('[name="source_chunk_ids"]')).toHaveValue(chunkId);
});

test("expired draft save preserves local fields and offers sign in", async ({ page }) => {
  await page.route("**/api/flashcards", (route) => route.fulfill({ status: 401, json: { detail: "expired" } }));
  const deckId = "123e4567-e89b-12d3-a456-426614174000";
  const cardId = "223e4567-e89b-12d3-a456-426614174000";
  await loadScript(page, `<main data-draft-review data-deck-id="${deckId}" data-revision="4" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="${cardId}" data-discarded="false"><form data-card-form data-recovery-key="card:${cardId}"><textarea name="question">Local prompt</textarea><textarea name="answer">Local answer</textarea><input name="tags"><input name="topic_ids"><input type="radio" name="evidence_kind" value="personal" checked><select name="citation_choice"><option value="">Personal</option></select><button>Save card</button></form></li></ol></main>`);
  await page.locator('[name="question"]').fill("Unsaved local prompt");

  await page.getByRole("button", { name: "Save card" }).click();

  await expect(page.getByRole("link", { name: /sign in, then return to this draft/i })).toHaveAttribute("href", "/login");
  const recovery = await page.evaluate((id) => JSON.parse(sessionStorage.getItem("flashcard-draft-reapply-" + id)), deckId);
  expect(recovery["card:" + cardId].question).toBe("Unsaved local prompt");
  expect(recovery["card:" + cardId].answer).toBe("Local answer");
});

test("generation sends exactly one stable scope and opens review rather than study", async ({ page }) => {
  const requests = [];
  await page.route("**/flashcards/drafts/**", (route) => route.fulfill({ status: 200, contentType: "text/html", body: "<h1>Review draft</h1>" }));
  await page.route("**/api/flashcards", async (route) => {
    const body = route.request().postDataJSON();
    requests.push(body);
    if (body.action === "topics" || body.action === "candidates") return route.fulfill({ status: 200, json: [] });
    if (body.action === "generate") return route.fulfill({ status: 200, json: { deck: { id: "323e4567-e89b-12d3-a456-426614174000" } } });
    return route.fulfill({ status: 200, json: [] });
  });
  await loadScript(page, `<section data-flash-create><form><fieldset><input type="radio" name="scope_type" value="enrollment_id" checked><label data-scope="enrollment_id"><select name="enrollment_id"><option value="123e4567-e89b-12d3-a456-426614174000">Module</option></select></label><label data-scope="topic_ids"><select name="topic_ids" multiple></select></label><label data-scope="source_ids"><select name="source_ids" multiple></select></label><div data-scope="source_chunk_ids"><select name="chunk_topic_id"></select><select name="chunk_source_id"></select><select name="source_chunk_ids" multiple></select></div><label data-scope="wiki_page_id"><select name="wiki_page_id"></select></label><input name="deck_title"><input name="limit" value="10"><input type="checkbox" name="regenerate"><span data-scope-effective></span><button type="submit">Generate review draft</button></fieldset></form><p data-flash-create-status></p></section>`);
  await page.getByRole("button", { name: "Generate review draft" }).click();
  await expect.poll(() => requests.some((item) => item.action === "generate")).toBe(true);
  const generate = requests.find((item) => item.action === "generate");
  expect(generate.payload).toMatchObject({ enrollment_id: "123e4567-e89b-12d3-a456-426614174000", limit: 10, regenerate: false });
  expect(generate.payload).not.toHaveProperty("topic_ids");
  await expect.poll(() => new URL(page.url()).pathname).toBe("/flashcards/drafts/323e4567-e89b-12d3-a456-426614174000");
});
