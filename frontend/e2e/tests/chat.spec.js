const { expect, test } = require("@playwright/test");

async function loadChat(page, selectedValue) {
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
      <form id="cp-chat-form" data-endpoint="/api/chat">
        <textarea id="cp-chat-input"></textarea>
        <button id="cp-chat-send" type="submit" disabled>Send</button>
      </form>
    </main>
  `);
  await page.addScriptTag({ url: "/app.js" });
}

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
  await expect(page.getByText("Answer lacks cited support", { exact: true })).toBeVisible();

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
  await page.getByRole("button", { name: "Send" }).click();
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
