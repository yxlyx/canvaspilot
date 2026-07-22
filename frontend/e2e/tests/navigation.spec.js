const { expect, test } = require("@playwright/test");

const playwrightPort = process.env.PLAYWRIGHT_PORT || "3101";
const cookieURL = new URL("/", process.env.PLAYWRIGHT_BASE_URL || `http://127.0.0.1:${playwrightPort}`).toString();

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

test("legacy workspace pages keep fixtures behind exact explicit demo mode", async ({ context, page }) => {
  await context.addCookies([
    { name: "cp_session", value: "browser-boundary", url: cookieURL },
  ]);

  await page.goto("/dashboard");
  await expect(page.getByRole("heading", { name: "Workspace" })).toBeVisible();
  await expect(page.getByText("Unavailable", { exact: true })).toHaveCount(4);
  await expect(page.getByText(/temporarily unavailable/).first()).toBeVisible();
  await expect(page.locator("body")).not.toContainText("CS2030S");
  await expect(page.locator("body")).not.toContainText("Immutable lists");

  for (const path of ["/sources", "/flashcards", "/chat"]) {
    await page.goto(path);
    await expect(page.getByRole("heading", { name: "Service unavailable" })).toBeVisible();
    await expect(page.locator("body")).not.toContainText("CS2030S");
    await expect(page.locator("body")).not.toContainText("Immutable lists");
  }

  await page.goto("/sources?mock=true");
  await expect(page.getByRole("heading", { name: "Service unavailable" })).toBeVisible();
  await expect(page.locator('[data-cp-demo="true"]')).toHaveCount(0);

  await page.goto("/sources?mock=1");
  await expect(page.locator('[data-cp-demo="true"]')).toHaveCount(1);
  await expect(page.getByText(/synthetic fixtures, not live workspace data/i)).toBeVisible();
  await page.getByRole("button", { name: /Ready/ }).click();
  await expect.poll(() => new URL(page.url()).searchParams.get("status")).toBe("ready");
  await expect.poll(() => new URL(page.url()).searchParams.get("mock")).toBe("1");
});

test("demo flashcards require reveal and show balanced disabled ratings", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/flashcards?mock=1");

  await expect(page.locator(".cp-deck-row[aria-current=true]")).toHaveCount(1);
  await expect(page.getByText("Due now", { exact: true })).toHaveCount(0);
  await expect(page.getByText("scheduled review", { exact: true })).toHaveCount(0);

  const firstCard = page.locator(".flashcard").first();
  const details = firstCard.locator("details");
  const ratingPanel = page.locator("#cp-rating-panel");
  const ratings = ratingPanel.locator("button");
  await expect(ratings).toHaveCount(4);
  await expect(ratings.first()).toBeHidden();
  const closedRatings = await ratingPanel.evaluate((actions) => ({
    display: getComputedStyle(actions).display,
    height: actions.getBoundingClientRect().height,
  }));
  expect(closedRatings).toEqual({ display: "none", height: 0 });
  await details.getByText("Reveal answer", { exact: true }).click();
  await expect(ratingPanel.getByText(/ratings are disabled and are not saved/i)).toBeVisible();
  for (const label of ["Again", "Hard", "Good", "Easy"]) {
    await expect(ratingPanel.getByRole("button", { name: label, exact: true })).toBeDisabled();
  }

  const boxes = await ratings.evaluateAll((buttons) =>
    buttons.map((button) => {
      const box = button.getBoundingClientRect();
      return { width: box.width, top: box.top };
    }),
  );
  expect(Math.abs(boxes[0].width - boxes[1].width)).toBeLessThan(1);
  expect(Math.abs(boxes[0].width - boxes[2].width)).toBeLessThan(1);
  expect(Math.abs(boxes[0].top - boxes[1].top)).toBeLessThan(1);
  expect(boxes[2].top).toBeGreaterThan(boxes[0].top);
  expect(Math.abs(boxes[2].top - boxes[3].top)).toBeLessThan(1);

  const questionTop = await firstCard.locator("h2").evaluate((heading) => heading.getBoundingClientRect().top);
  expect(questionTop).toBeLessThan(700);
});

test("landing workflow numbers are visibly illustrative", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByText(/Illustrative product preview · synthetic demo data, not a live workspace/i)).toBeVisible();
});

test("authenticated live chat reports backend unavailability without demo fallback", async ({
  context,
  page,
}) => {
  await context.addCookies([
    { name: "cp_session", value: "browser-boundary", url: cookieURL },
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
