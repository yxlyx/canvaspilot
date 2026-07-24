const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const path = require("node:path");

const playwrightPort = process.env.PLAYWRIGHT_PORT || "3101";
const cookieURL = new URL("/", process.env.PLAYWRIGHT_BASE_URL || `http://127.0.0.1:${playwrightPort}`).toString();

test("private mutation forms fail closed as POST when JavaScript is unavailable", async () => {
  for (const relative of [
    "app/settings/index.zig",
    "app/settings/providers.zig",
    "app/sources/papers/index.zig",
    "app/sources/papers/[id].zig",
    "app/wiki/guides.zig",
  ]) {
    const source = fs.readFileSync(path.join(__dirname, "../..", relative), "utf8");
    const enhancedForms = source.match(/<form[^>]+data-(?:settings-form|m3-form|paper-upload)[^>]*>/g) || [];
    expect(enhancedForms.length).toBeGreaterThan(0);
    for (const form of enhancedForms) {
      const normalized = form.replaceAll('\\"', '"');
      expect(normalized).toContain('method="post"');
      expect(normalized).toMatch(/action="\/api\/(?:settings|m3)"/);
    }
  }
  const paperDetail = fs.readFileSync(path.join(__dirname, "../../app/sources/papers/[id].zig"), "utf8");
  expect(paperDetail).toContain('value=\\"paper.deleteQuestion\\"');
});

test("Wiki downloads retain the no-JavaScript export form contract", async () => {
  const settings = fs.readFileSync(path.join(__dirname, "../../app/settings/data.zig"), "utf8").replaceAll('\\"', '"');
  const wiki = fs.readFileSync(path.join(__dirname, "../../app/wiki/index.zig"), "utf8").replaceAll('\\"', '"');
  for (const source of [settings, wiki]) {
    expect(source).toContain('method="post" action="/api/m3" data-wiki-export><input type="hidden" name="action" value="wiki.export">');
  }
  expect(settings).toContain('<button class="cp-btn cp-btn-ghost" name="selection" value="all" type="submit">Download Wiki</button>');
  expect(settings).not.toContain('type="button" data-wiki-export');
  expect(wiki).toContain('name="selection" value="selected" type="submit">Download selected pages</button>');
  expect(wiki).toContain('name="page_ids"');
});

test("explicit demo renders grounded and insufficient study-guide states", async ({ page }) => {
  await page.goto("/wiki/guides?mock=1");
  await expect(page.getByRole("heading", { name: "Study guides" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Grounded before generated." })).toBeVisible();
  await page.getByLabel("Evidence state").selectOption("insufficient");
  await page.getByRole("button", { name: "Preview state" }).click();
  await expect(page.getByRole("heading", { name: "No unsupported guide was created." })).toBeVisible();
  await expect(page.locator("main")).toHaveAttribute("id", "main");
});

test("anonymous explicit demo shell shows sign in and never sign out", async ({ page }) => {
  await page.goto("/dashboard?mock=1");
  await expect(page.locator('[data-cp-auth="anonymous"][data-cp-demo="true"]')).toHaveCount(1);
  await expect(page.locator(".cp-sidebar").getByRole("link", { name: "Sign in" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Sign out" })).toHaveCount(0);
});

test("live backend failure is unavailable and never falls back", async ({ context, page }) => {
  await context.addCookies([{ name: "cp_session", value: "browser-token", url: cookieURL, httpOnly: true, sameSite: "Lax" }]);
  await page.goto("/outputs");
  await expect(page.getByRole("heading", { name: "Service unavailable" })).toBeVisible();
  await expect(page.getByText(/No demo data has been substituted/)).toBeVisible();
  await expect(page.getByText("Immutable lists and streams — cited summary")).toHaveCount(0);
});

test("navigation is keyboard reachable at narrow viewport and preserves demo mode", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 667 });
  await page.goto("/wiki/guides?mock=1");
  await page.keyboard.press("Tab");
  await expect(page.getByRole("link", { name: "Skip to content" })).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.locator("#main")).toBeFocused();
  const primary = page.getByRole("navigation", { name: "Primary mobile" });
  await expect(primary).toBeVisible();
  await expect(primary.getByRole("link")).toHaveCount(5);
  const menu = page.locator(".cp-mobile-header .cp-mobile-menu");
  await menu.locator("summary").focus();
  await page.keyboard.press("Enter");
  await expect(menu.getByRole("navigation", { name: "Mobile menu" })).toBeVisible();
  await expect(menu.getByRole("link", { name: "Wiki" })).toHaveAttribute("aria-current", "page");
  await menu.getByRole("link", { name: "Workspace" }).click();
  await expect(page).toHaveURL(/\/dashboard\?mock=1$/);
  await expect(page.locator('[data-cp-demo="true"]')).toHaveCount(1);
  const layout = await page.evaluate(() => ({
    pageFits: document.documentElement.scrollWidth <= document.documentElement.clientWidth,
    barFits: document.querySelector(".cp-bottomnav").scrollWidth <= document.querySelector(".cp-bottomnav").clientWidth,
  }));
  expect(layout).toEqual({ pageFits: true, barFits: true });
});

test("mobile Ask keeps module scope and source evidence discoverable", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/chat?mock=1");
  await expect(page.getByLabel("Module")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Evidence in scope" })).toBeVisible();
  await expect(page.locator(".chat-context").getByRole("link").first()).toBeVisible();
  const layout = await page.evaluate(() => ({ width: document.documentElement.scrollWidth, viewport: document.documentElement.clientWidth }));
  expect(layout.width).toBeLessThanOrEqual(layout.viewport);
});

test("mobile Menu works without JavaScript and exposes POST sign-out", async ({ browser }) => {
  const context = await browser.newContext({ baseURL: cookieURL, javaScriptEnabled: false, viewport: { width: 360, height: 640 } });
  await context.addCookies([{ name: "cp_session", value: "browser-token", url: cookieURL }]);
  const page = await context.newPage();
  await page.goto("/wiki/guides");
  const menu = page.locator(".cp-mobile-header .cp-mobile-menu");
  await menu.locator("summary").click();
  await expect(menu.getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/settings");
  await expect(menu.locator('form[action="/logout"][method="post"]')).toHaveCount(1);
  await expect(menu.getByRole("button", { name: "Sign out" })).toBeVisible();
  await context.close();
});

test("ordinary M3 forms retain a no-JavaScript submission path", async ({ browser }) => {
  const context = await browser.newContext({ baseURL: cookieURL, javaScriptEnabled: false });
  await context.addCookies([{ name: "cp_session", value: "browser-token", url: cookieURL }]);
  const page = await context.newPage();
  await page.goto("/login");
  await page.setContent(`<main><form method="post" action="/api/m3">
    <input name="action" value="output.create"><input name="output_type" value="study_guide">
    <input name="scope_type" value="topic"><input name="topic" value="recursion">
    <button type="submit">Generate guide</button></form></main>`);
  await page.getByRole("button", { name: "Generate guide" }).click();
  await expect(page).toHaveURL(/\/wiki\/guides\?error=1$/);
  await context.close();
});

test("live mutation payload and canonical download work without secret URLs", async ({ page }) => {
  await page.goto("/login");
  const requests = [];
  await page.route("**/api/m3", async (route) => {
    const body = route.request().postDataJSON(); requests.push(body);
    if (body.action === "page.download") {
      return route.fulfill({ status: 200, contentType: "text/markdown", headers: { "content-disposition": 'attachment; filename="safe-page.md"' }, body: "# Canonical\n" });
    }
    return route.fulfill({ status: 201, contentType: "application/json", body: JSON.stringify({ status: "grounded" }) });
  });
  await page.setContent(`<main id="main"><form data-m3-form>
    <input name="action" value="output.create"><select name="output_type"><option value="summary">Summary</option></select>
    <select name="scope_type"><option value="topic">Topic</option></select><input name="topic" value="recursion">
    <button type="submit">Generate</button><p class="cp-form-status" role="status"></p></form>
    <form data-page-download data-slug="safe-page"><button type="submit">Download</button><p class="cp-form-status" role="status"></p></form>
    <script src="/m3.js"></script></main>`);
  await page.getByRole("button", { name: "Generate" }).click();
  await expect(page.getByText("Saved.")).toBeVisible();
  expect(requests[0]).toMatchObject({ action: "output.create", payload: { output_type: "summary", topic: "recursion" } });
  expect(requests[0].idempotency_key).toMatch(/^[A-Za-z0-9_-]{16,128}$/);
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download" }).click();
  expect((await download).suggestedFilename()).toBe("safe-page.md");
  expect(requests[1]).toMatchObject({ action: "page.download", slug: "safe-page" });
  expect(requests[1].idempotency_key).toBeUndefined();
  expect(requests.every((request) => !JSON.stringify(request).includes("api_key"))).toBeTruthy();
});

test("signup mode has matching title, heading, active tab, and focused server errors", async ({ page }) => {
  await page.goto("/login?mode=signup&error=email_taken");
  await expect(page).toHaveTitle("Create account — WikiBase");
  await expect(page.getByRole("heading", { name: "Build from your sources." })).toBeVisible();
  await expect(page.getByRole("link", { name: "Create account" })).toHaveAttribute("aria-current", "page");
  await expect(page.getByRole("alert")).toHaveText("An account already exists for that email.");
  await expect(page.getByRole("alert")).toBeFocused();
});

test("output scope enables one input and rejects whitespace topics before requesting", async ({ page }) => {
  await page.goto("/login");
  let calls = 0;
  await page.route("**/api/m3", async (route) => { calls += 1; await route.fulfill({ status: 201, contentType: "application/json", body: "{}" }); });
  await page.setContent(`<main><form data-m3-form><input name="action" value="output.create">
    <select name="scope_type" data-scope-select><option value="source_ids">Sources</option><option value="topic">Topic</option></select>
    <label data-scope-field="source_ids"><select name="source_ids"><option value="source-1">Source</option></select></label>
    <label data-scope-field="topic"><input name="topic"></label><button>Generate</button><p class="cp-form-status"></p></form><script src="/m3.js"></script></main>`);
  const scope = page.locator('[name="scope_type"]');
  await scope.selectOption("topic");
  await expect(page.locator('[name="source_ids"]')).toBeDisabled();
  await expect(page.locator('[name="topic"]')).toBeEnabled();
  await page.locator('[name="topic"]').fill("   ");
  await page.getByRole("button", { name: "Generate" }).click();
  await expect(page.getByText("Enter a topic that is not blank.")).toHaveAttribute("role", "alert");
  await expect(page.locator('[name="topic"]')).toBeFocused();
  expect(calls).toBe(0);
});

test("structured FastAPI errors are readable, announced, and focused", async ({ page }) => {
  await page.goto("/login");
  await page.route("**/api/m3", (route) => route.fulfill({
    status: 422,
    contentType: "application/json",
    body: JSON.stringify({ detail: [{ type: "string_too_short", loc: ["body", "topic"], msg: "Topic must not be blank", input: "" }] }),
  }));
  await page.setContent(`<main><form data-m3-form><input name="action" value="health.run"><button>Run</button><p class="cp-form-status"></p></form><script src="/m3.js"></script></main>`);
  await page.getByRole("button", { name: "Run" }).click();
  const alert = page.getByRole("alert");
  await expect(alert).toHaveText("topic: Topic must not be blank");
  await expect(alert).not.toContainText("[object Object]");
  await expect(alert).toBeFocused();
});

test("malformed legacy health IDs fail closed without contacting the health service", async ({ context, page }) => {
  await context.addCookies([{ name: "cp_session", value: "browser-token", url: cookieURL }]);
  const response = await page.goto("/health/not%20valid");
  expect(response.status()).toBe(404);
  await expect(page.getByRole("heading", { name: /not found/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Service unavailable" })).toHaveCount(0);
});

test("legacy study-tool routes preserve query state while moving into the reskin", async ({ page }) => {
  const routes = [
    ["/health?mock=1&severity=warning", /\/sources\/health\?mock=1&severity=warning$/],
    ["/marked-papers?mock=1&cursor=demo", /\/sources\/papers\?mock=1&cursor=demo$/],
    ["/history?mock=1&type=content", /\/wiki\/activity\?mock=1&type=content$/],
    ["/history?mock=1&type=wiki_revision", /\/wiki\/activity\?mock=1&type=content$/],
    ["/history?mock=1&type=source_change", /\/wiki\/activity\?mock=1&type=content$/],
    ["/history?mock=1&type=citations", /\/wiki\/activity\?mock=1&type=evidence$/],
    ["/progress?mock=1", /\/wiki\/knowledge\?mock=1$/],
    ["/outputs?mock=1&state=grounded", /\/wiki\/guides\?mock=1&state=grounded$/],
  ];
  for (const [legacy, canonical] of routes) {
    await page.goto(legacy);
    await expect(page).toHaveURL(canonical);
    await expect(page.locator('[data-cp-demo="true"]')).toHaveCount(1);
  }
});

test("legacy dashboard module links show the workspace wiki instead of a false empty state", async ({ page }) => {
  await page.goto("/wiki?mock=1&module=CS2040S");
  await expect(page.getByText(/Showing all workspace articles/)).toBeVisible();
  await expect(page.getByRole("link", { name: /Read article/ }).first()).toBeVisible();
  await expect(page.getByRole("heading", { name: "No connected topics found" })).toHaveCount(0);
});

test("Knowledge recommendations retain contextual destinations", async ({ page }) => {
  await page.goto("/wiki/knowledge?mock=1");
  await expect(page.getByText("Collect more recursion evidence")).toBeVisible();
  await expect(page.getByRole("link", { name: "Review wiki notes" })).toHaveAttribute("href", /\/wiki\/immutable-lists\?mock=1$/);
  await expect(page.getByRole("link", { name: "Practice cited cards" })).toHaveAttribute("href", /\/flashcards\?deck=deck-streams&mock=1$/);
  await expect(page.getByRole("link", { name: "Review paper evidence" })).toHaveAttribute("href", /\/sources\/papers\/demo-paper-functional-midterm\?mock=1$/);
});

test("dark landing closing panel keeps readable editorial contrast", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Switch to dark mode" }).click();
  const colors = await page.locator(".wb-closing").evaluate((section) => ({
    background: getComputedStyle(section).backgroundColor,
    heading: getComputedStyle(section.querySelector("h2")).color,
    body: getComputedStyle(section.querySelector("p")).color,
  }));
  expect(colors).toEqual({ background: "rgb(36, 36, 33)", heading: "rgb(241, 239, 232)", body: "rgb(170, 169, 162)" });
});

test("authentication refreshes account theme and motion cookies", async () => {
  const signin = fs.readFileSync(path.join(__dirname, "../../api/auth/signin.zig"), "utf8");
  const register = fs.readFileSync(path.join(__dirname, "../../api/auth/register.zig"), "utf8");
  expect(signin).toContain("parsed.value.motion_preference");
  expect(signin).toContain("lib.session.motionCookie");
  expect(register).toContain('lib.session.motionCookie("system")');
});

test("account theme cookie is applied during the initial page boot", async ({ context, page }) => {
  await context.addCookies([{ name: "wb_theme_preference", value: "dark", url: cookieURL, sameSite: "Lax" }]);
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
});

test("shell theme toggle persists the cookie and account preference", async ({ page }) => {
  const requests = [];
  await page.goto("/login");
  await page.route("**/api/settings", async (route) => {
    requests.push(new URLSearchParams(route.request().postData() || ""));
    await route.fulfill({ status: 200, contentType: "application/json", body: '{"ok":true}' });
  });
  await page.setContent(`<main><strong data-cp-account-name>Account</strong>
    <button type="button" data-cp-theme-toggle aria-label="Switch to dark mode"></button>
    <script>document.documentElement.dataset.theme = "light";</script><script src="/app.js"></script></main>`);

  await page.getByRole("button", { name: "Switch to dark mode" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect.poll(async () => (await page.context().cookies()).find((cookie) => cookie.name === "wb_theme_preference")?.value).toBe("dark");
  await expect.poll(() => requests.length).toBe(1);
  expect(requests[0].get("action")).toBe("preferences.theme");
  expect(requests[0].get("theme")).toBe("dark");
});

test("saved account motion preference remains reduced after reload", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/login");
  await page.route("**/api/settings", (route) => route.fulfill({ status: 200, contentType: "application/json", body: '{"ok":true}' }));
  await page.setContent(`<main><form method="post" action="/api/settings" data-settings-form data-appearance-form>
    <input name="action" value="preferences.update"><input name="theme" value="system">
    <label><input type="radio" name="motion_preference" value="system" checked>Follow system</label>
    <label><input type="radio" name="motion_preference" value="reduce">Reduce motion</label>
    <button type="submit">Save appearance</button><p class="cp-form-status" role="status"></p>
    </form><script src="/settings.js"></script></main>`);

  await page.getByRole("radio", { name: "Reduce motion" }).check();
  await page.getByRole("button", { name: "Save appearance" }).click();
  await expect(page.getByText("Saved.")).toBeVisible();
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("data-motion", "reduce");
  await expect.poll(() => page.locator(".wb-marketing-nav").evaluate((node) => Number.parseFloat(getComputedStyle(node).transitionDuration))).toBeLessThanOrEqual(0.00001);
});

test("live source preview stays metadata-only and source saves report pending ingestion", async ({ page }) => {
  await page.goto("/login");
  let sourceRequest;
  await page.route("**/api/sources", (route) => {
    sourceRequest = route.request().postDataJSON();
    return route.fulfill({
      status: 201,
      contentType: "application/json",
      body: JSON.stringify({ id: "source-1", title: "Lecture notes", status: "pending" }),
    });
  });
  await page.setContent(`<main>
    <input id="cp-source-search"><select id="cp-source-format"><option value="">All formats</option></select>
    <span id="cp-source-count"></span><h2 id="cp-source-heading"></h2><div id="cp-source-empty" hidden></div>
    <section id="cp-document-grid"><article class="document-card" data-title="Lecture notes" data-module="CS2040S" data-format="URL" data-status="pending" data-tags="Trees">
      <button type="button" data-source-preview>Preview</button></article></section>
    <div id="cp-source-preview-modal" hidden><section><button type="button" data-close-source-modal>Close</button>
      <h3 id="cp-preview-paper-title">Source</h3><h2 id="cp-preview-title">Source</h2><p id="cp-preview-detail"></p>
      <span id="cp-preview-status"></span><dl><dd id="cp-preview-context"></dd><dd id="cp-preview-format"></dd><dd id="cp-preview-topics"></dd></dl>
    </section></div>
    <form id="cp-add-source-form" action="/api/sources"><input id="cp-new-source-title" value="New source"><input id="cp-new-source-url" value="https://example.test/notes"><input id="cp-new-source-module" value="CS2040S"><button type="submit">Save source</button><p class="cp-form-status"></p></form>
    <script src="/app.js"></script></main>`);

  await page.getByRole("button", { name: "Preview" }).click();
  await expect(page.locator("#cp-preview-context")).toHaveText("CS2040S");
  await expect(page.locator("#cp-preview-format")).toHaveText("URL");
  await expect(page.locator("#cp-preview-topics")).toHaveText("Trees");
  await expect(page.locator("#cp-source-preview-modal")).not.toContainText("linked wiki claims");
  await expect(page.locator("#cp-source-preview-modal")).not.toContainText("Traceability preserved");

  await page.getByRole("button", { name: "Save source" }).click();
  await expect(page.locator(".cp-form-status")).toHaveText("Source saved as metadata. Ingestion has not started.");
  expect(sourceRequest).toEqual({ source_type: "link", origin: "web", title: "New source", source_url: "https://example.test/notes", course_context: "CS2040S" });
});

test("forms lock before async work, reject duplicate submits, and focus errors", async ({ page }) => {
  await page.goto("/login");
  let calls = 0; let finish;
  await page.route("**/api/m3", async (route) => { calls += 1; await new Promise((resolve) => { finish = resolve; }); await route.fulfill({ status: 422, contentType: "application/json", body: '{"error":"invalid scope"}' }); });
  await page.setContent(`<main><article><form data-m3-form><input name="action" value="output.create"><input name="scope_type" value="topic"><input name="topic" value="x"><button type="submit">Generate</button><p class="cp-form-status" role="status"></p></form></article><script src="/m3.js"></script></main>`);
  await page.getByRole("button", { name: "Generate" }).click();
  await expect(page.locator("form input").first()).toBeDisabled();
  await page.locator("form").evaluate((form) => { form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })); form.requestSubmit(); });
  expect(calls).toBe(1); finish();
  await expect(page.getByText("invalid scope")).toBeFocused();
  await expect(page.getByRole("button", { name: "Generate" })).toBeEnabled();
});

test("provider save omits fixed endpoints and preserves custom and Azure endpoints", async ({ page }) => {
  await page.goto("/login");
  const requests = [];
  await page.route("**/api/m3", async (route) => { requests.push(route.request().postDataJSON()); await route.fulfill({ status: 200, contentType: "application/json", body: "{}" }); });
  await page.setContent(`<main>
    <form data-m3-form><input name="action" value="provider.save"><input name="provider" value="openai"><input name="api_key" value="replacement-key"><input name="model" value="gpt-4o"><input name="endpoint" value="https://api.openai.com/v1"><button>Save OpenAI</button><p class="cp-form-status"></p></form>
    <form data-m3-form><input name="action" value="provider.save"><input name="provider" value="azure_openai"><input name="api_key" value="replacement-key"><input name="model" value="deployment"><input name="endpoint" value="https://course.openai.azure.com"><button>Save Azure</button><p class="cp-form-status"></p></form>
    <script src="/m3.js"></script></main>`);
  await page.getByRole("button", { name: "Save OpenAI" }).click();
  await page.getByRole("button", { name: "Save Azure" }).click();
  expect(requests[0].payload).toEqual({ provider: "openai", api_key: "replacement-key", model: "gpt-4o" });
  expect(requests[1].payload.endpoint).toBe("https://course.openai.azure.com");
});

test("marked-paper upload and destructive confirmations are guarded", async ({ page }) => {
  await page.goto("/login");
  const requests = [];
  await page.route("**/api/m3", async (route) => { requests.push(route.request().postDataJSON()); await route.fulfill({ status: 200, contentType: "application/json", body: "{}" }); });
  await page.setContent(`<main><form data-paper-upload><input type="file" name="paper"><button>Upload</button><p class="cp-form-status"></p></form>
    <form data-m3-form data-confirm="Delete this paper?"><input name="action" value="paper.delete"><input name="id" value="paper-1"><button>Delete paper</button><p class="cp-form-status"></p></form><script src="/m3.js"></script></main>`);
  await page.locator('input[type="file"]').setInputFiles({ name: "paper.md", mimeType: "text/markdown", buffer: Buffer.from("Q1: Explain\n\nFeedback: Good") });
  await page.getByRole("button", { name: "Upload" }).click();
  await expect.poll(() => requests.length).toBe(1);
  expect(requests[0]).toMatchObject({ action: "paper.upload", payload: { filename: "paper.md", content_type: "text/markdown" } });
  await page.goto("/login");
  await page.setContent(`<main><form data-m3-form data-confirm="Delete this paper?"><input name="action" value="paper.delete"><input name="id" value="paper-1"><button>Delete paper</button><p class="cp-form-status"></p></form><script src="/m3.js"></script></main>`);
  page.once("dialog", (dialog) => dialog.dismiss()); await page.getByRole("button", { name: "Delete paper" }).click(); expect(requests).toHaveLength(1);
  page.once("dialog", (dialog) => dialog.accept()); await page.getByRole("button", { name: "Delete paper" }).click(); await expect.poll(() => requests.length).toBe(2);
});

test("demo settings and wiki expose no mutation controls", async ({ page }) => {
  await page.goto("/settings/providers?mock=1");
  await expect(page.locator('input[type="password"]')).toHaveCount(0);
  await expect(page.locator("form[data-m3-form]")).toHaveCount(0);
  await expect(page.getByText(/Read-only preview/).first()).toBeVisible();
  await expect(page.locator("html")).not.toContainText(/sk-[A-Za-z0-9]/);
  await page.goto("/settings/data?mock=1");
  await expect(page.locator("form[data-wiki-export]")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Download Wiki" })).toBeDisabled();
  await page.goto("/wiki?mock=1");
  await expect(page.getByRole("button", { name: /Export|Download/ })).toHaveCount(0);
  await expect(page.locator("[data-page-download]")).toHaveCount(0);
  await expect(page.getByRole("link", { name: /Read article/ }).first()).toBeVisible();
});

test("signed-in shell hydrates the account identity and unread notification state", async ({ page }) => {
  await page.goto("/login");
  await page.route("**/api/me", (route) => route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify({ name: "Ada Lovelace", email: "ada@example.edu" }),
  }));
  await page.route("**/api/notifications/unread-count", (route) => route.fulfill({
    status: 200,
    contentType: "application/json",
    body: JSON.stringify({ unread_count: 3 }),
  }));
  await page.setContent(`<main><strong data-cp-account-name>Account</strong><span data-cp-account-initial>W</span>
    <a data-cp-notification-link aria-label="Notifications"><i hidden></i></a><script src="/app.js"></script></main>`);
  await expect(page.locator("[data-cp-account-name]")).toHaveText("Ada Lovelace");
  await expect(page.locator("[data-cp-account-initial]")).toHaveText("A");
  await expect(page.locator("[data-cp-notification-link]")).toHaveAttribute("aria-label", "Notifications, 3 unread");
  await expect(page.locator("[data-cp-notification-link] i")).not.toHaveAttribute("hidden", "");
});

test("Data & privacy Wiki control requests a full canonical export", async ({ page }) => {
  await page.goto("/login");
  let request;
  await page.route("**/api/m3", async (route) => {
    request = route.request().postDataJSON();
    await route.fulfill({ status: 200, contentType: "application/zip", headers: { "content-disposition": 'attachment; filename="workspace-wiki.zip"' }, body: Buffer.from([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0]) });
  });
  await page.setContent(`<main><form method="post" action="/api/m3" data-wiki-export>
    <button name="selection" value="all" type="submit">Download Wiki</button><p class="cp-form-status" role="status"></p>
    </form><script src="/m3.js"></script></main>`);
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download Wiki" }).click();
  expect((await download).suggestedFilename()).toBe("workspace-wiki.zip");
  expect(request).toEqual({ action: "wiki.export" });
});

test("Wiki dialog sends every selected page through the enhanced export flow", async ({ page }) => {
  await page.goto("/login");
  let request;
  await page.route("**/api/m3", async (route) => {
    request = route.request().postDataJSON();
    await route.fulfill({ status: 200, contentType: "application/zip", headers: { "content-disposition": 'attachment; filename="selected-wiki.zip"' }, body: Buffer.from([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0]) });
  });
  await page.setContent(`<main><form method="post" action="/api/m3" data-wiki-export>
    <input type="hidden" name="action" value="wiki.export">
    <input type="checkbox" name="page_ids" value="page-one" checked>
    <input type="checkbox" name="page_ids" value="page-two" checked>
    <button name="selection" value="selected" type="submit">Download selected pages</button><p class="cp-form-status" role="status"></p>
    </form><script src="/m3.js"></script></main>`);
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download selected pages" }).click();
  expect((await download).suggestedFilename()).toBe("selected-wiki.zip");
  expect(request).toEqual({ action: "wiki.export", payload: { page_ids: ["page-one", "page-two"] } });
});

test("account archive downloads only valid ZIP attachments", async ({ page }) => {
  await page.goto("/login");
  let valid = false;
  await page.route("**/api/settings", (route) => valid
    ? route.fulfill({ status: 200, contentType: "application/zip", headers: { "content-disposition": 'attachment; filename="account.zip"' }, body: Buffer.from([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0]) })
    : route.fulfill({ status: 200, contentType: "text/html", body: "<html>Sign in</html>" }));
  await page.setContent(`<main><form method="post" action="/api/settings" data-settings-form data-download>
    <input name="action" value="account.export"><input name="current_password" value="secret">
    <button type="submit">Download archive</button><p class="cp-form-status" role="status" tabindex="-1"></p>
    </form><script src="/settings.js"></script></main>`);
  let downloads = 0;
  page.on("download", () => { downloads += 1; });
  await page.getByRole("button", { name: "Download archive" }).click();
  await expect(page.getByRole("alert")).toHaveText("The archive response was not a valid ZIP download.");
  expect(downloads).toBe(0);

  valid = true;
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download archive" }).click();
  expect((await download).suggestedFilename()).toBe("account.zip");
  await expect(page.getByText("Archive downloaded.")).toBeVisible();
});

test("settings validation focuses and marks the implicated field", async ({ page }) => {
  await page.goto("/login");
  await page.route("**/api/settings", (route) => route.fulfill({
    status: 422,
    contentType: "application/json",
    body: JSON.stringify({ detail: [{ loc: ["body", "display_name"], msg: "Enter a display name" }] }),
  }));
  await page.setContent(`<main><form method="post" action="/api/settings" data-settings-form>
    <label>Display name <input name="display_name" value="A"></label>
    <button type="submit">Save profile</button><p class="cp-form-status" role="status" tabindex="-1"></p>
    </form><script src="/settings.js"></script></main>`);
  await page.getByRole("button", { name: "Save profile" }).click();
  await expect(page.locator('[name="display_name"]')).toBeFocused();
  await expect(page.locator('[name="display_name"]')).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByRole("alert")).toHaveText("Enter a display name");
});
