const { expect, test } = require("@playwright/test");

async function loadChat(page, selectedValue, providerReady = true) {
  await page.goto("/login");
  await page.setContent(`
    <main>
      <select id="cp-chat-module" data-scope-kind="enrollment">
        <option value="" data-code="All sources"${selectedValue ? "" : " selected"}>All imported sources</option>
        <option value="123e4567-e89b-12d3-a456-426614174000" data-code="CS2040S"${selectedValue ? " selected" : ""}>CS2040S Data Structures</option>
      </select>
      <span id="cp-chat-module-code"></span>
      <span id="cp-chat-composer-code"></span>
      <div id="cp-chat-log"><div id="cp-chat-welcome"></div></div>
      <button id="cp-chat-clear" disabled>Clear conversation</button>
      <form id="cp-chat-form" data-endpoint="/api/chat" data-provider-ready="${providerReady}">
        <textarea id="cp-chat-input"></textarea>
        <span id="cp-chat-input-limit" hidden></span>
        <button id="cp-chat-send" type="submit" disabled>Send</button>
      </form>
    </main>
  `);
  await page.addScriptTag({ url: "/vendor/marked.umd.js" });
  await page.addScriptTag({ url: "/vendor/purify.min.js" });
  await page.addScriptTag({ url: "/app.js" });
}

test("chat keeps scope available while provider-gated controls stay disabled", async ({ page }) => {
  await loadChat(page, true, false);
  await expect(page.locator("#cp-chat-module")).toBeEnabled();
  await expect(page.locator("#cp-chat-input")).toBeDisabled();
  await expect(page.locator("#cp-chat-send")).toBeDisabled();
});

test("rendered chat page loads local Markdown dependencies and keyboard guidance", async ({ page, request }) => {
  await page.goto("/chat?mock=1");
  await expect(page.locator("#cp-chat-input")).toBeVisible();
  await expect(page.getByText(/Enter to send/)).toBeVisible();
  expect(await page.evaluate(() => typeof window.marked?.parse)).toBe("function");
  expect(await page.evaluate(() => typeof window.DOMPurify?.sanitize)).toBe("function");
  expect((await request.get("/vendor/marked.umd.js")).status()).toBe(200);
  expect((await request.get("/vendor/purify.min.js")).status()).toBe(200);
});

test("chat proxy accepts the backend character limit for multibyte text", async ({ request }) => {
  const text = "🙂".repeat(8000);
  const response = await request.post("/api/chat?mock=1", {
    data: {
      message: text,
      history: [
        { role: "user", content: text },
        { role: "assistant", content: text },
      ],
    },
  });
  expect(response.status()).toBe(200);

  const rejected = await request.post("/api/chat?mock=1", {
    data: { message: "🙂".repeat(8001), history: [] },
  });
  expect(rejected.status()).toBe(400);
});

test("composer enforces the character limit by Unicode code points", async ({ page }) => {
  const requests = [];
  await page.route("**/api/chat", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, json: { message: "Accepted.", citations: [], grounded: true } });
  });
  await loadChat(page, true);

  const input = page.locator("#cp-chat-input");
  await input.fill("🙂".repeat(8001));
  await expect(input).toHaveAttribute("aria-invalid", "true");
  await expect(page.locator("#cp-chat-input-limit")).toContainText("8,001 / 8,000 characters");
  await expect(page.locator("#cp-chat-send")).toBeDisabled();

  await input.fill("🙂".repeat(8000));
  await expect(input).not.toHaveAttribute("aria-invalid");
  await expect(page.locator("#cp-chat-send")).toBeEnabled();
  await input.press("Enter");
  await expect(page.getByText("Accepted.")).toBeVisible();
  expect(Array.from(requests[0].message)).toHaveLength(8000);
});

test("chat sends the selected local enrollment and opens the exact source record", async ({ page }) => {
  const requests = [];
  await page.route("**/api/chat", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({
      status: 200,
      json: {
        message: "Grounded response.",
        citations: [
          {
            title: "Lecture notes",
            url: "https://example.com/lecture-notes",
            source_id: "223e4567-e89b-12d3-a456-426614174000",
            snippet: "Exact supporting excerpt.",
            reference_number: 5,
          },
          { title: "Tutorial", url: "https://example.com/tutorial", snippet: "Second excerpt.", reference_number: 2 },
          { title: "Textbook", url: "https://example.com/textbook", snippet: "Third excerpt.", reference_number: 4 },
          { title: "Summary", url: "https://example.com/summary", snippet: "Fourth excerpt.", reference_number: 1 },
        ],
      },
    });
  });
  await loadChat(page, true);
  await page.locator("#cp-chat-input").fill("What does this module say?");
  await page.getByRole("button", { name: "Send" }).click();

  await expect.poll(() => requests.length).toBe(1);
  expect(requests[0].enrollment_id).toBe("123e4567-e89b-12d3-a456-426614174000");
  expect(requests[0]).not.toHaveProperty("module_id");
  await expect(page.locator(".citation").first()).toHaveAttribute(
    "href",
    "/sources?source=223e4567-e89b-12d3-a456-426614174000&enrollment_id=123e4567-e89b-12d3-a456-426614174000",
  );
  await expect(page.locator(".citation > span")).toHaveText(["5", "2", "4", "1"]);
  await expect(page.locator(".citation").nth(1)).toHaveAttribute("data-external-host", "example.com");
  await expect(page.locator(".citation").nth(1)).toHaveAttribute("rel", "nofollow noopener noreferrer");
});

test("chat renders safe, structured Markdown answers", async ({ page }) => {
  const markdown = [
    "## Core ideas",
    "",
    "**Foundations** connect the main structures:",
    "",
    "- Arrays offer indexed access.",
    "- Trees support hierarchical search with `O(log n)` balanced lookup.",
    "",
    "> Compare the trade-offs before choosing a structure.",
    "",
    "```js",
    "const queue = [];",
    "```",
    "",
    "[Course page](https://example.com/course) and [unsafe link](javascript:window.markdownAttack=true)",
    "<img src=x onerror=\"window.markdownAttack=true\"><input type=\"password\" title=\"Sign in again\">",
    "<a class=\"modal-backdrop cp-btn\" href=\"/login\">Injected action</a>",
  ].join("\n");
  await page.route("**/api/chat", async (route) => {
    await route.fulfill({ status: 200, json: { message: markdown, citations: [], grounded: true } });
  });
  await loadChat(page, true);
  await page.locator("#cp-chat-input").fill("Give me a structured overview");
  await page.getByRole("button", { name: "Send" }).click();

  const answer = page.locator(".chat-markdown");
  await expect(answer.getByRole("heading", { name: "Core ideas", level: 3 })).toBeVisible();
  await expect(answer.locator("strong")).toHaveText("Foundations");
  await expect(answer.locator("li")).toHaveCount(2);
  await expect(answer.locator("pre code")).toHaveText("const queue = [];");
  await expect(answer.locator("img, input")).toHaveCount(0);
  await expect(answer.getByText("Injected action")).not.toHaveClass(/modal-backdrop|cp-btn/);
  await expect(answer.locator('a[href^="javascript:"]')).toHaveCount(0);
  await expect(answer.getByText("unsafe link")).not.toHaveAttribute("href");
  await expect(answer.getByRole("link", { name: /Course page/ })).toHaveAttribute("data-external-host", "example.com");
  await expect(answer.getByRole("link", { name: /Course page/ })).toHaveAttribute("rel", "nofollow noopener noreferrer");
  expect(await page.evaluate(() => window.markdownAttack)).toBeUndefined();
});

test("Enter sends, Shift+Enter adds a line, and follow-ups include conversation history", async ({ page }) => {
  const requests = [];
  await page.route("**/api/chat", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({
      status: 200,
      json: { message: requests.length === 1 ? "First grounded reply." : "Follow-up grounded reply.", citations: [], grounded: true },
    });
  });
  await loadChat(page, true);

  const input = page.locator("#cp-chat-input");
  await input.fill("正在选择候选词");
  await input.dispatchEvent("compositionstart");
  await input.press("Enter");
  await input.dispatchEvent("compositionend");
  expect(requests).toHaveLength(0);
  await page.waitForTimeout(0);

  await input.fill("Explain balanced trees");
  await input.press("Enter");
  await expect(page.getByText("First grounded reply.")).toBeVisible();
  await expect(input).toHaveValue("");

  const initialHeight = await input.evaluate((element) => Number.parseFloat(element.style.height));
  await input.fill(Array.from({ length: 18 }, (_, index) => `Line ${index + 1}`).join("\n"));
  const grownComposer = await input.evaluate((element) => ({ height: Number.parseFloat(element.style.height), overflow: element.style.overflowY }));
  expect(grownComposer.height).toBeGreaterThan(initialHeight);
  expect(grownComposer.height).toBeLessThanOrEqual(180);
  expect(grownComposer.overflow).toBe("auto");

  await input.fill("And deletion?");
  await input.press("Shift+Enter");
  await expect(input).toHaveValue("And deletion?\n");
  expect(requests).toHaveLength(1);
  await input.type("Keep it concise.");
  await input.press("Enter");
  await expect(page.getByText("Follow-up grounded reply.")).toBeVisible();

  expect(requests).toHaveLength(2);
  expect(requests[1].message).toBe("And deletion?\nKeep it concise.");
  expect(requests[1].history).toEqual([
    { role: "user", content: "Explain balanced trees" },
    { role: "assistant", content: "First grounded reply." },
  ]);
});

test("long chat sessions keep the newest supported conversation context", async ({ page }) => {
  const requests = [];
  await page.route("**/api/chat", async (route) => {
    const requestBody = route.request().postDataJSON();
    requests.push(requestBody);
    await route.fulfill({ status: 200, json: { message: `Reply ${requests.length}`, citations: [], grounded: true } });
  });
  await loadChat(page, true);

  const input = page.locator("#cp-chat-input");
  for (let turn = 1; turn <= 22; turn += 1) {
    await input.fill(`Question ${turn}`);
    await input.press("Enter");
    await expect(page.getByText(`Reply ${turn}`, { exact: true })).toBeVisible();
  }

  expect(requests[21].history).toHaveLength(10);
  expect(requests[21].history[0]).toEqual({ role: "user", content: "Question 17" });
  expect(requests[21].history[9]).toEqual({ role: "assistant", content: "Reply 21" });
});

test("large valid turns stay below the frontend request-size boundary", async ({ page }) => {
  const requests = [];
  const reply = "答".repeat(7000);
  await page.route("**/api/chat", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, json: { message: reply, citations: [], grounded: true } });
  });
  await loadChat(page, true);

  const input = page.locator("#cp-chat-input");
  for (let turn = 1; turn <= 4; turn += 1) {
    await input.fill("问".repeat(7000) + String(turn));
    await input.press("Enter");
    await expect.poll(() => requests.length).toBe(turn);
    await expect(input).toBeEnabled();
  }

  expect(requests[3].history).toHaveLength(2);
  expect(Buffer.byteLength(JSON.stringify(requests[3]), "utf8")).toBeLessThan(128 * 1024);
});

test("oversized assistant replies are safely bounded in follow-up history", async ({ page }) => {
  const requests = [];
  const oversizedReply = "A".repeat(9000);
  await page.route("**/api/chat", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, json: { message: requests.length === 1 ? oversizedReply : "Follow-up succeeded.", citations: [], grounded: true } });
  });
  await loadChat(page, true);

  const input = page.locator("#cp-chat-input");
  await input.fill("Give me the full explanation");
  await input.press("Enter");
  await expect(page.locator(".chat-markdown p")).toHaveText(oversizedReply);
  await input.fill("What is the key takeaway?");
  await input.press("Enter");
  await expect(page.getByText("Follow-up succeeded.")).toBeVisible();

  expect(requests[1].history).toHaveLength(2);
  expect(requests[1].history[1].content).toHaveLength(8000);
});

test("chat clears the composer while sending and restores a failed question", async ({ page }) => {
  await page.route("**/api/chat", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 120));
    await route.fulfill({ status: 503, json: { error: "retrieval_unavailable", detail: "Source retrieval stopped before an answer was created." } });
  });
  await loadChat(page, true);

  const input = page.locator("#cp-chat-input");
  await input.fill("Keep this question safe");
  await input.press("Enter");
  await expect(input).toHaveValue("");
  await expect(page.getByText("Retrieval interrupted", { exact: true })).toBeVisible();
  await expect(input).toHaveValue("Keep this question safe");
});

test("chat distinguishes no evidence, provider attention, and retryable retrieval", async ({ page }) => {
  let mode = "no_evidence";
  let retrievalCalls = 0;
  await page.route("**/api/chat", async (route) => {
    if (mode === "no_evidence") return route.fulfill({ status: 200, json: { message: "No relevant content found in your workspace sources.", citations: [], grounded: false, confidence: 0, outcome: "no_evidence" } });
    if (mode === "ungrounded") return route.fulfill({ status: 200, json: { message: "This answer has no valid citations.", citations: [], grounded: false, confidence: 0, outcome: "answer" } });
    if (mode === "provider") return route.fulfill({ status: 409, json: { error: "provider_unavailable", detail: "The answer provider needs attention. Your sources remain available." } });
    retrievalCalls += 1;
    if (retrievalCalls === 1) return route.fulfill({ status: 503, json: { error: "retrieval_unavailable", detail: "Source retrieval stopped before an answer was created." } });
    return route.fulfill({ status: 200, json: { message: "Recovered grounded response.", citations: [], grounded: true } });
  });
  await loadChat(page, true);

  await page.locator("#cp-chat-input").fill("Question with no evidence");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page.getByText("No matching evidence", { exact: true })).toBeVisible();
  await expect(page.locator(".student-turn")).toHaveCount(1);

  await page.getByRole("button", { name: "Clear conversation" }).click();
  mode = "ungrounded";
  await page.locator("#cp-chat-input").fill("Question without valid citations");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page.getByText("General answer", { exact: true })).toBeVisible();

  await page.getByRole("button", { name: "Clear conversation" }).click();
  mode = "provider";
  await page.locator("#cp-chat-input").fill("Question needing a provider");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page.getByText("Answer provider unavailable", { exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Open provider settings" })).toHaveAttribute("href", "/settings/providers");
  await expect(page.locator("#cp-chat-input")).toHaveValue("Question needing a provider");

  await page.getByRole("button", { name: "Clear conversation" }).click();
  mode = "retrieval";
  await page.locator("#cp-chat-input").fill("Retry this question");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page.getByText("Retrieval interrupted", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Retry safely" }).click();
  await expect(page.getByText("Recovered grounded response.")).toBeVisible();
  await expect(page.locator(".student-turn")).toHaveCount(1);
  expect(retrievalCalls).toBe(2);
});

test("chat all-source mode sends no enrollment scope", async ({ page }) => {
  const requests = [];
  await page.route("**/api/chat", async (route) => {
    requests.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, json: { message: "Grounded response.", citations: [] } });
  });
  await loadChat(page, false);
  await page.locator("#cp-chat-input").fill("Search everything");
  await page.getByRole("button", { name: "Send" }).click();

  await expect.poll(() => requests.length).toBe(1);
  expect(requests[0].enrollment_id).toBeNull();
  expect(requests[0]).not.toHaveProperty("module_id");
});
