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
