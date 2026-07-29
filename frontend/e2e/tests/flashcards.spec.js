const fs = require("node:fs");
const path = require("node:path");
const { expect, test } = require("@playwright/test");

async function loadScript(page, body) {
  await page.goto("/login", { waitUntil: "commit" });
  await page.setContent(body);
  await page.addScriptTag({ url: "/app.js" });
}

function generationFixture() {
  return `<section data-flash-create><form><fieldset>
    <input type="radio" name="scope_type" value="enrollment_id" checked>
    <div data-scope="enrollment_id"><div data-choice-list="enrollment_id"><label><input type="radio" name="enrollment_id" value="123e4567-e89b-12d3-a456-426614174000" checked>Module</label></div></div>
    <div data-scope="topic_ids" hidden><div data-choice-list="topic_ids"></div></div>
    <div data-scope="source_ids" hidden><div data-choice-list="source_ids"></div></div>
    <div data-scope="source_chunk_ids" hidden><select name="chunk_topic_id"></select><select name="chunk_source_id"></select><div data-choice-list="source_chunk_ids"></div></div>
    <div data-scope="wiki_page_id" hidden><div data-choice-list="wiki_page_id"></div></div>
    <input name="deck_title"><input type="radio" name="limit_choice" value="10" checked><input name="custom_limit" value="10"><input type="checkbox" name="regenerate"><span data-scope-effective></span><button type="submit">Generate review draft</button>
  </fieldset></form><p data-flash-create-status></p></section>`;
}

test("draft review summarizes generation details instead of printing snapshot JSON", async () => {
  const root = path.resolve(__dirname, "../..");
  const pageSource = fs.readFileSync(path.join(root, "app/flashcards/drafts/[deck_id].zig"), "utf8");
  const styles = fs.readFileSync(path.join(root, "app/_styles.css"), "utf8");

  expect(pageSource).not.toContain("valueJson");
  expect(pageSource).toContain("evidence passage");
  expect(pageSource).toContain("generator_snapshot, \"provider\"");
  expect(styles).toContain(".cp-provenance { display: grid");
  expect(styles).toContain(".cp-draft-card > form");
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
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="4" data-lifecycle="draft"><div data-draft-status></div><form data-deck-form><input name="title" value="Original"><button>Save title</button></form><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false"><form data-card-form><textarea name="question">Prompt</textarea><textarea name="answer">Answer</textarea><input name="tags"><input name="topic_ids"><input type="radio" name="evidence_kind" value="personal" checked><select name="citation_choice"><option value="">No citation</option></select><button>Save card</button></form></li></ol></main>`);
  await page.locator('[name="title"]').fill("Unsaved local title");
  await page.getByRole("button", { name: "Save title" }).click();
  await expect(page.getByText(/changed elsewhere/i)).toBeVisible();
  await expect(page.locator('[name="title"]')).toHaveValue("Unsaved local title");
  await expect(page.getByRole("button", { name: /reload latest and reapply/i })).toBeVisible();
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
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="5" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list><li data-card-id="223e4567-e89b-12d3-a456-426614174000" data-discarded="false"></li></ol><button data-approve-all>Approve all supported</button></main>`);
  await Promise.all([
    page.waitForNavigation(),
    page.getByRole("button", { name: "Approve all supported" }).click(),
  ]);
  await expect.poll(() => requests.some((item) => item.action === "approve")).toBe(true);

  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="6" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list></ol><button data-publish>Publish approved snapshot</button></main>`);
  await Promise.all([
    page.waitForNavigation(),
    page.getByRole("button", { name: "Publish approved snapshot" }).click(),
  ]);
  await expect.poll(() => requests.some((item) => item.action === "publish")).toBe(true);

  page.on("dialog", (dialog) => dialog.accept());
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="7" data-lifecycle="approved"><div data-draft-status></div><ol data-card-list></ol><button data-retire>Retire approved deck</button></main>`);
  await Promise.all([
    page.waitForNavigation(),
    page.getByRole("button", { name: "Retire approved deck" }).click(),
  ]);
  await expect.poll(() => requests.some((item) => item.action === "retire")).toBe(true);
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

test("generation links to provider settings when no answer provider is available", async ({ page }) => {
  await page.route("**/api/flashcards", async (route) => {
    const body = route.request().postDataJSON();
    if (body.action === "generate") return route.fulfill({ status: 409, json: { error: "provider_not_configured", detail: "Connect a provider" } });
    return route.fulfill({ status: 200, json: [] });
  });
  await loadScript(page, generationFixture());

  await page.getByRole("button", { name: "Generate review draft" }).click();

  await expect(page.getByRole("link", { name: "Open provider settings" })).toHaveAttribute("href", "/settings/providers");
  await expect(page.locator("[data-flash-create-status]")).toContainText("scope selection is preserved");
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
  await loadScript(page, generationFixture());
  await page.getByRole("button", { name: "Generate review draft" }).click();
  await expect.poll(() => requests.some((item) => item.action === "generate")).toBe(true);
  const generate = requests.find((item) => item.action === "generate");
  expect(generate.payload).toMatchObject({ enrollment_id: "123e4567-e89b-12d3-a456-426614174000", limit: 10, regenerate: false });
  expect(generate.payload).not.toHaveProperty("topic_ids");
  await expect.poll(() => new URL(page.url()).pathname).toBe("/flashcards/drafts/323e4567-e89b-12d3-a456-426614174000");
});
