const { test, expect } = require("@playwright/test");
const fs = require("node:fs");
const path = require("node:path");

const playwrightPort = process.env.PLAYWRIGHT_PORT || "3101";
const cookieURL = new URL("/", process.env.PLAYWRIGHT_BASE_URL || `http://127.0.0.1:${playwrightPort}`).toString();

test("private mutation forms fail closed as POST when JavaScript is unavailable", async () => {
  for (const relative of ["app/settings/providers.zig", "app/marked-papers/index.zig", "app/marked-papers/[id].zig"]) {
    const source = fs.readFileSync(path.join(__dirname, "../..", relative), "utf8");
    const enhancedForms = source.match(/<form[^>]+data-(?:m3-form|paper-upload)[^>]*>/g) || [];
    expect(enhancedForms.length).toBeGreaterThan(0);
    for (const form of enhancedForms) {
      expect(form).toContain('method=\\"post\\"');
      expect(form).toContain('action=\\"/api/m3\\"');
    }
  }
});

test("explicit demo renders grounded and insufficient evidence states", async ({ page }) => {
  await page.goto("/outputs?mock=1");
  await expect(page.getByRole("heading", { name: "Cited outputs" })).toBeVisible();
  await expect(page.getByText("Synthetic demo", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: /Immutable lists and streams/ })).toBeVisible();
  await page.getByLabel("Preview state").selectOption("insufficient");
  await page.getByRole("button", { name: "Preview synthetic state" }).click();
  await expect(page.getByRole("heading", { name: "No cited output generated" })).toBeVisible();
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
  await page.goto("/outputs?mock=1");
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
  await expect(menu.getByRole("link", { name: "Outputs" })).toHaveAttribute("aria-current", "page");
  await menu.getByRole("link", { name: "Knowledge" }).click();
  await expect(page).toHaveURL(/\/progress\?mock=1$/);
  await expect(page.getByText("Synthetic demo", { exact: true })).toBeVisible();
  const layout = await page.evaluate(() => ({
    pageFits: document.documentElement.scrollWidth <= document.documentElement.clientWidth,
    barFits: document.querySelector(".cp-bottomnav").scrollWidth <= document.querySelector(".cp-bottomnav").clientWidth,
  }));
  expect(layout).toEqual({ pageFits: true, barFits: true });
});

test("mobile Menu works without JavaScript and exposes POST sign-out", async ({ browser }) => {
  const context = await browser.newContext({ baseURL: cookieURL, javaScriptEnabled: false, viewport: { width: 360, height: 640 } });
  await context.addCookies([{ name: "cp_session", value: "browser-token", url: cookieURL }]);
  const page = await context.newPage();
  await page.goto("/outputs?mock=1");
  const menu = page.locator(".cp-mobile-header .cp-mobile-menu");
  await menu.locator("summary").click();
  await expect(menu.getByRole("link", { name: "Providers" })).toHaveAttribute("href", "/settings/providers?mock=1");
  await expect(menu.locator('form[action="/logout"][method="post"]')).toHaveCount(1);
  await expect(menu.getByRole("button", { name: "Sign out" })).toBeVisible();
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
  await expect(page.locator("h1", { hasText: "Create your account" })).toBeVisible();
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

test("malformed health IDs render a health-specific client error", async ({ context, page }) => {
  await context.addCookies([{ name: "cp_session", value: "browser-token", url: cookieURL }]);
  const response = await page.goto("/health/not%20valid");
  expect(response.status()).toBe(400);
  await expect(page.getByRole("heading", { name: "Invalid health finding" })).toBeVisible();
  await expect(page.getByText(/No health service request was made/)).toBeVisible();
  await expect(page.getByRole("heading", { name: "Service unavailable" })).toHaveCount(0);
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
  await page.goto("/wiki?mock=1");
  await expect(page.getByRole("button", { name: /Export|Download/ })).toHaveCount(0);
  await expect(page.locator("[data-page-download]")).toHaveCount(0);
  await expect(page.getByRole("link", { name: /Read article/ }).first()).toBeVisible();
});
