const { test, expect } = require("@playwright/test");

const run = (status, stages) => ({
  id: "123e4567-e89b-12d3-a456-426614174000",
  source_id: "223e4567-e89b-12d3-a456-426614174000",
  source_version_id: "323e4567-e89b-12d3-a456-426614174000",
  status,
  current_stage: "parse_index",
  attempt_count: 0,
  created_at: "2026-07-28T12:00:00Z",
  updated_at: "2026-07-28T12:00:01Z",
  stages,
});

const stage = (status) => ({ name: "parse_index", status, attempt_count: status === "queued" ? 0 : 1, max_attempts: 3, available_at: "2026-07-28T12:00:00Z" });

test("intake retries a network failure with one stable idempotency key", async ({ page }) => {
  await page.goto("/login");
  const keys = [];
  let calls = 0;
  await page.route("**/api/sources/import", async (route) => {
    calls += 1;
    keys.push(route.request().headers()["idempotency-key"]);
    if (calls === 1) return route.abort("connectionreset");
    return route.fulfill({ status: 201, contentType: "application/json", body: JSON.stringify({ import_status: "queued", duplicate: false, job_id: run("queued", [stage("queued")]).id, source: { id: "source-1" } }) });
  });
  await page.setContent(`<main><input id="cp-source-search"><select id="cp-source-format"><option value=""></option></select><div id="cp-document-grid"></div><div id="cp-add-source-modal"><button data-source-mode="upload">Upload files</button><button data-source-mode="link">Add link</button><button data-source-mode="paste">Paste text</button><form id="cp-add-source-form" action="/api/sources/import"><input name="mode" value="upload"><div data-source-panel="upload"></div><div data-source-panel="link"></div><div data-source-panel="paste"><textarea id="cp-source-content">Durable notes</textarea><select id="cp-paste-format"><option value="plain_text">Text</option></select></div><input id="cp-new-source-title" value="Notes"><input id="cp-new-source-module"><button type="submit">Add</button><p class="cp-form-status"></p></form></div><script src="/app.js"></script></main>`);
  await page.getByRole("button", { name: "Paste text" }).click();
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.locator(".cp-form-status")).toContainText("queued");
  expect(calls).toBe(2);
  expect(keys[0]).toBe(keys[1]);
});

test("text upload status and submission enforce the backend character ceiling", async ({ page }) => {
  await page.goto("/login");
  let calls = 0;
  await page.route("**/api/sources/import", async (route) => {
    calls += 1;
    return route.fulfill({ status: 201, contentType: "application/json", body: "{}" });
  });
  await page.setContent(`<main><input id="cp-source-search"><select id="cp-source-format"><option value=""></option></select><div id="cp-document-grid"></div><div id="cp-add-source-modal"><button data-source-mode="upload">Upload files</button><button data-source-mode="link">Add link</button><button data-source-mode="paste">Paste text</button><form id="cp-add-source-form" action="/api/sources/import"><input name="mode" value="upload"><div data-source-panel="upload"><input id="cp-source-files" type="file" multiple><ul class="source-file-list"></ul></div><div data-source-panel="link"></div><div data-source-panel="paste"><textarea id="cp-source-content"></textarea></div><input id="cp-new-source-title" value="Notes"><input id="cp-new-source-module"><button type="submit">Add</button><p class="cp-form-status"></p></form></div><script src="/app.js"></script></main>`);

  for (const file of [
    { name: "notes.txt", mimeType: "text/plain" },
    { name: "notes.md", mimeType: "text/markdown" },
  ]) {
    await page.locator("#cp-source-files").setInputFiles({ ...file, buffer: Buffer.alloc(2000001) });
    await expect(page.locator(".source-file-list")).toContainText("Over 2,000,000 characters");
    await page.getByRole("button", { name: "Add", exact: true }).click();
    await expect(page.locator(".cp-form-status")).toHaveText(`${file.name} exceeds the 2,000,000 character text limit.`);
  }

  await page.locator("#cp-source-files").setInputFiles([
    { name: "valid.pdf", mimeType: "application/pdf", buffer: Buffer.from("pdf") },
    { name: "too-long.txt", mimeType: "text/plain", buffer: Buffer.alloc(2000001) },
  ]);
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.locator(".cp-form-status")).toHaveText("too-long.txt exceeds the 2,000,000 character text limit.");
  expect(calls).toBe(0);

  await page.locator("#cp-source-files").setInputFiles({
    name: "at-limit.txt",
    mimeType: "text/plain",
    buffer: Buffer.alloc(2000000),
  });
  await expect(page.locator(".source-file-list")).toContainText("Ready to import");
  await expect(page.locator(".cp-form-status")).toBeEmpty();

  for (const file of [
    { name: "paper.pdf", mimeType: "application/pdf" },
    { name: "scan.png", mimeType: "image/png" },
  ]) {
    await page.locator("#cp-source-files").setInputFiles({ ...file, buffer: Buffer.alloc(10 * 1024 * 1024) });
    await expect(page.locator(".source-file-list")).toContainText("Ready to import");
  }
  expect(calls).toBe(0);

  await page.locator("#cp-source-files").setInputFiles({
    name: "multilingual.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("界".repeat(1000000)),
  });
  await expect(page.locator(".source-file-list")).toContainText("Ready to import");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect.poll(() => calls).toBe(1);
});

test("polling advances queued to running without wiping the timeline on failure", async ({ page }) => {
  await page.goto("/login");
  let calls = 0;
  await page.route("**/api/processing", async (route) => {
    calls += 1;
    if (calls === 1) return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(run("running", [stage("running")])) });
    return route.fulfill({ status: 503, contentType: "application/json", body: '{"error":"offline"}' });
  });
  await page.setContent(`<main><article data-source-id="${run().source_id}" data-latest-run-id="${run().id}"><p data-source-processing><span data-source-stage>Parse and index</span><span data-source-run-status>queued</span><span data-source-run-updated>1m ago</span></p></article><section data-processing-panel><p data-processing-error role="alert" hidden></p><article data-processing-run="${run().id}" data-run-status="queued"><header><span class="status-pill">queued</span></header><ol><li data-stage="parse_index" data-status="queued"><strong>Parse and index</strong><span data-stage-explanation>Waiting for an available local processing worker.</span><span data-stage-meta>time</span></li></ol></article></section><script src="/app.js"></script></main>`);
  await expect(page.locator("[data-processing-run]")).toHaveAttribute("data-run-status", "running");
  await expect(page.locator("[data-stage='parse_index'] [data-stage-explanation]")).toContainText("timeline updates automatically");
  await expect(page.locator("[data-source-run-status]")).toHaveText("running");
  await expect(page.locator("[data-source-run-updated]")).toHaveText("just now");
  await expect(page.locator("[data-processing-error]")).toContainText("preserved", { timeout: 7000 });
  await expect(page.locator("[data-stage='parse_index'] strong")).toHaveText("Parse and index");
});

test("a selected historical run never overwrites the latest source-card state", async ({ page }) => {
  await page.goto("/login");
  const latest = run("running", [stage("running")]);
  const historical = { ...run("running", [stage("running")]), id: "623e4567-e89b-12d3-a456-426614174000", current_stage: "wiki" };
  await page.route("**/api/processing", async (route) => {
    const body = route.request().postDataJSON();
    const value = body.id === historical.id ? historical : latest;
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(value) });
  });
  await page.setContent(`<main><article data-source-id="${latest.source_id}" data-latest-run-id="${latest.id}"><span data-source-stage>Queued</span><span data-source-run-status>queued</span><span data-source-run-updated>1m ago</span></article><section data-processing-panel><p data-processing-error hidden></p><article data-processing-run="${latest.id}" data-run-status="queued"><header><span class="status-pill">queued</span></header></article><article data-processing-run="${historical.id}" data-run-status="queued"><header><span class="status-pill">queued</span></header></article></section><script src="/app.js"></script></main>`);
  await expect(page.locator("[data-source-stage]")).toHaveText("Parse and index");
  await expect(page.locator("[data-source-run-status]")).toHaveText("running");
});

test("paused provider runs expose guidance and retry remains explicit", async ({ page }) => {
  await page.goto("/login");
  const actions = [];
  await page.route("**/api/processing", async (route) => {
    const body = route.request().postDataJSON();
    actions.push(body.action);
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(run(body.action === "run.cancel" ? "cancelled" : "queued", [stage("queued")])) });
  });
  await page.setContent(`<main><section data-processing-panel><p data-processing-error role="alert" hidden></p><article data-processing-run="${run().id}" data-run-status="paused"><header><span class="status-pill">paused</span></header><p><strong>Paused:</strong> provider_unavailable <a href="/settings/providers">Open settings</a></p><ol><li data-stage="parse_index" data-status="paused"><strong>Parse and index</strong><span>Status: paused</span><span>time</span></li></ol><button data-processing-action="run.retry" data-run-id="${run().id}">Retry failed stage</button></article></section><script src="/app.js"></script></main>`);
  await expect(page.getByRole("link", { name: "Open settings" })).toHaveAttribute("href", "/settings/providers");
  await page.getByRole("button", { name: "Retry failed stage" }).click();
  await expect.poll(() => actions).toContain("run.retry");
});

test("Wiki content remains visible when status polling fails", async ({ page }) => {
  await page.goto("/login");
  await page.route("**/api/processing", (route) => route.fulfill({ status: 503, contentType: "application/json", body: '{"error":"offline"}' }));
  await page.setContent(`<main><article><h1>Prior valid Wiki</h1><p>Cited content remains readable.</p></article><section data-processing-panel><p data-processing-error role="alert" hidden></p><article data-processing-run="${run().id}" data-run-status="running"><header><span class="status-pill">running</span></header></article></section><script src="/app.js"></script></main>`);
  await expect(page.getByRole("heading", { name: "Prior valid Wiki" })).toBeVisible();
  await expect(page.locator("[data-processing-error]")).toContainText("preserved");
  await expect(page.getByText("Cited content remains readable.")).toBeVisible();
});

test("policy controls save independent durable values", async ({ page }) => {
  await page.goto("/login");
  let body;
  await page.route("**/api/processing", async (route) => {
    body = route.request().postDataJSON();
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body.payload) });
  });
  await page.setContent(`<main><form data-processing-policy-form><label><input type="checkbox" name="process_sources">Process sources</label><label><input type="checkbox" name="map_topics" checked>Map topics</label><label><input type="checkbox" name="compile_wiki" checked>Compile Wiki</label><select name="flashcard_mode"><option value="draft" selected>Draft</option></select><button>Save processing policy</button><p class="cp-form-status" tabindex="-1"></p></form><script src="/settings.js"></script></main>`);
  await page.getByRole("button", { name: "Save processing policy" }).click();
  await expect(page.locator(".cp-form-status")).toContainText("Queued source runs are paused");
  expect(body.payload).toEqual({ process_sources: false, map_topics: true, compile_wiki: true, flashcard_mode: "draft" });
});

test("explicit learning demo disables policy and target fieldsets semantically", async ({ page }) => {
  await page.goto("/settings/learning?mock=1");
  const policy = page.getByRole("group", { name: "Processing policy controls" });
  const defaults = page.getByRole("group", { name: "Default learning scope and daily target" });
  await expect(policy).toHaveAttribute("disabled", "");
  await expect(defaults).toHaveAttribute("disabled", "");
  await expect(policy.locator("input, select")).toHaveCount(4);
  await expect(defaults.locator("input, select")).toHaveCount(2);
  for (const control of await policy.locator("input, select").all()) await expect(control).toBeDisabled();
  for (const control of await defaults.locator("input, select").all()) await expect(control).toBeDisabled();
});

test("exact source context focuses and opens the owned source record", async ({ page }) => {
  await page.goto("/login");
  const sourceId = "223e4567-e89b-12d3-a456-426614174000";
  await page.setContent(`<main><input id="cp-source-search"><select id="cp-source-format"><option value=""></option></select><div id="cp-document-grid"><article class="document-card is-focused" data-source-id="${sourceId}" data-title="Exact source" data-module="CS2040S" data-format="Text" data-status="ready" tabindex="-1"><button data-source-preview>Preview Exact source</button></article></div><div id="cp-source-preview-modal" hidden><button data-close-source-modal>Close</button><h2 id="cp-preview-title"></h2><span id="cp-preview-detail"></span><span id="cp-preview-status"></span><span id="cp-preview-context"></span><span id="cp-preview-format"></span><span id="cp-preview-topics"></span><span id="cp-preview-paper-title"></span></div><script src="/app.js"></script></main>`);
  await expect(page.locator("#cp-source-preview-modal")).toBeVisible();
  await expect(page.locator("#cp-preview-title")).toHaveText("Exact source");
  await expect(page.locator(".document-card.is-focused")).toHaveAttribute("data-source-id", sourceId);
});

test("flashcard provenance follows each exact source identifier", async ({ page }) => {
  await page.goto("/login");
  const sourceId = "223e4567-e89b-12d3-a456-426614174000";
  await page.setContent(`<main><div id="cp-flash-review"></div><article id="cp-flashcard"><span id="cp-card-number"></span><span id="cp-card-question"></span><details id="cp-card-details"><summary id="cp-reveal-card">Reveal</summary><div id="cp-card-answer"><span id="cp-card-answer-text"></span><a id="cp-card-source-link"><span id="cp-card-source"></span></a><span id="cp-card-page"></span><a id="cp-card-context-link">Open context</a></div><div id="cp-rating-panel"></div></details></article><div id="cp-flash-data"><span data-card-id="card" data-question="Question" data-answer="Answer" data-source="Owned source" data-source-id="${sourceId}"></span></div><script src="/app.js"></script></main>`);
  await expect(page.locator("#cp-card-source-link")).toHaveAttribute("href", `/sources?source=${sourceId}`);
  await expect(page.locator("#cp-card-context-link")).toHaveAttribute("href", `/sources?source=${sourceId}`);
});

test("draft decks are separate from the practice queue on mobile demo", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/flashcards?mock=1");
  await expect(page.getByText("Synthetic demo").first()).toBeVisible();
  await page.getByText("Reveal answer").click();
  await expect(page.getByRole("button", { name: "Again" })).toBeDisabled();
});
