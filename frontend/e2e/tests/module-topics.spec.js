const { test, expect } = require("@playwright/test");
const path = require("node:path");

const asset = path.join(__dirname, "../../public/module-topics.js");
const enrollmentId = "123e4567-e89b-12d3-a456-426614174000";
const revisionId = "223e4567-e89b-12d3-a456-426614174000";
const topics = [
  { id: revisionId, title: "Asymptotic analysis", archived: false, state: "provisional", provenance: "nusmods lesson plan", source_sha256: "source-hash" },
  { id: enrollmentId, title: "Sorting", archived: false, state: "provisional", provenance: "nusmods lesson plan", source_sha256: "source-hash" },
];

async function mount(page, handler, demo = false) {
  await page.route("**/api/curriculum", async (route) => {
    const body = route.request().postDataJSON();
    const response = await handler(body);
    await route.fulfill({ status: response.status || 200, contentType: "application/json", body: JSON.stringify(response.body) });
  });
  await page.goto("/login");
  await page.setContent(`<main><section data-topic-manager data-enrollment-id="${enrollmentId}" data-demo="${demo}"><button type="button" data-review-topics>Review topics</button><div data-topic-editor hidden></div></section></main>`);
  await page.addScriptTag({ path: asset });
}

test("topic identities survive rename, reorder, archive, and save", async ({ page }) => {
  const requests = [];
  await mount(page, async (body) => {
    requests.push(body);
    if (body.action === "topics.list") return { body: topics };
    return { body: body.payload.topics.map((topic, position) => ({ ...topic, position, state: "canonical", provenance: "student review", source_sha256: "source-hash" })) };
  });

  await page.getByRole("button", { name: "Review topics" }).click();
  const titles = page.getByLabel("Topic title");
  await titles.nth(0).fill("Complexity analysis");
  await expect(page.locator(".module-topic-row").first().getByRole("button", { name: /Move Complexity analysis down/ })).toBeVisible();
  await page.locator(".module-topic-row").nth(1).getByRole("button", { name: /Move Sorting up/ }).click();
  await page.locator(".module-topic-row").nth(1).getByRole("checkbox", { name: /Archive Complexity analysis/ }).check();
  await page.getByRole("button", { name: "Save canonical topic map" }).click();

  const save = requests.find((request) => request.action === "topics.save");
  expect(save.payload.topics.map((topic) => topic.id)).toEqual([enrollmentId, revisionId]);
  expect(save.payload.topics[1]).toMatchObject({ title: "Complexity analysis", archived: true });
  await expect(page.getByRole("status")).toContainText("Canonical topic map saved");
});

test("syllabus proposals require an explicit accept or reject decision", async ({ page }) => {
  const requests = [];
  await mount(page, async (body) => {
    requests.push(body);
    if (body.action === "topics.list") return { body: topics };
    if (body.action === "revision.preview") return { body: { id: revisionId, algorithm: "deterministic-v1", status: "pending", base_topics: topics, proposed_topics: [{ id: revisionId, title: "Complexity" }], mapping: { preserved: [revisionId] } } };
    return { body: { id: revisionId, status: body.payload.decision === "accept" ? "accepted" : "rejected" } };
  });

  await page.getByRole("button", { name: "Review topics" }).click();
  await page.getByText("Propose topics from a processed syllabus source").click();
  await page.getByLabel("Ready syllabus source UUID").fill(enrollmentId);
  await page.getByRole("button", { name: "Preview syllabus proposal" }).click();
  await expect(page.getByRole("status")).toContainText("has not changed");
  await page.getByRole("button", { name: "Reject proposal" }).click();
  expect(requests.at(-1)).toMatchObject({ action: "revision.decide", payload: { decision: "reject" } });
  await expect(page.getByRole("status")).toContainText("was not changed");
});

test("mobile topic controls remain labelled and keyboard reachable", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mount(page, async () => ({ body: topics }));
  await page.getByRole("button", { name: "Review topics" }).focus();
  await page.keyboard.press("Enter");
  await page.getByRole("button", { name: "Add topic" }).focus();
  await page.keyboard.press("Enter");
  await expect(page.getByLabel("Topic title").last()).toBeFocused();
});

test("demo topic manager makes no mutation request", async ({ page }) => {
  let calls = 0;
  await mount(page, async () => { calls += 1; return { body: topics }; }, true);
  await expect(page.locator("[data-topic-editor]")).toBeHidden();
  expect(calls).toBe(0);
});
