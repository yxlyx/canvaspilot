const { expect, test } = require("@playwright/test");

test("explicit demo chat keeps demo context through a cited source link", async ({ page }) => {
  await page.goto("/chat?mock=1");

  await expect(page.locator('[data-cp-demo="true"]')).toHaveCount(1);
  await expect(page.locator("#cp-chat-form")).toHaveAttribute("data-endpoint", "/api/chat?mock=1");

  await page.locator("#cp-chat-input").fill("Summarise today's announcements");
  await page.locator("#cp-chat-send").click();

  const citation = page.locator("#cp-chat-log a").first();
  await expect(citation).toHaveAttribute("href", /[?&]mock=1(?:&|$)/);
  const [sourcePage] = await Promise.all([page.waitForEvent("popup"), citation.click()]);
  await expect(sourcePage).toHaveURL(/\/sources\?.*mock=1/);
  await expect(sourcePage.getByRole("heading", { name: "Source library" })).toBeVisible();
});

test("demo mutations are unavailable and anonymous live mutations require auth", async ({ page }) => {
  await page.goto("/login");

  const demoResult = await page.evaluate(async () => {
    const response = await fetch("/api/sync?mock=1", { method: "POST", body: "action=sync" });
    return { status: response.status, body: await response.text() };
  });
  expect(demoResult.status).toBe(400);
  expect(demoResult.body).toContain("sync is unavailable in demo mode");

  const authResult = await page.evaluate(async () => {
    const response = await fetch("/api/sync", { method: "POST", body: "action=sync" });
    return { status: response.status, url: response.url };
  });
  expect(authResult.status).toBe(200);
  expect(new URL(authResult.url).pathname).toBe("/login");
});

test("authenticated live chat reports backend unavailability without demo fallback", async ({
  context,
  page,
}) => {
  await context.addCookies([
    { name: "cp_session", value: "browser-boundary", url: "http://127.0.0.1:3101" },
  ]);
  await page.goto("/chat");

  const result = await page.evaluate(async () => {
    const response = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message: "live unavailable boundary" }),
    });
    return { status: response.status, body: await response.json() };
  });

  expect(result.status).toBe(502);
  expect(result.body).toEqual({
    error: "live chat is unavailable; no demo answer was substituted",
  });
});
