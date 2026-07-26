const { expect, test } = require("@playwright/test");

async function loadScript(page, body) {
  await page.goto("/login");
  await page.setContent(body);
  await page.addScriptTag({ url: "/app.js" });
}

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
  await page.getByRole("button", { name: "Approve all supported" }).click();
  await expect.poll(() => requests.some((item) => item.action === "approve")).toBe(true);

  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="6" data-lifecycle="draft"><div data-draft-status></div><ol data-card-list></ol><button data-publish>Publish approved snapshot</button></main>`);
  await page.getByRole("button", { name: "Publish approved snapshot" }).click();
  await expect.poll(() => requests.some((item) => item.action === "publish")).toBe(true);

  page.on("dialog", (dialog) => dialog.accept());
  await loadScript(page, `<main data-draft-review data-deck-id="123e4567-e89b-12d3-a456-426614174000" data-revision="7" data-lifecycle="approved"><div data-draft-status></div><ol data-card-list></ol><button data-retire>Retire approved deck</button></main>`);
  await page.getByRole("button", { name: "Retire approved deck" }).click();
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
