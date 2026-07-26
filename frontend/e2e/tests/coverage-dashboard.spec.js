const { test, expect } = require("@playwright/test");
const path = require("node:path");

const asset = path.join(__dirname, "../../public/coverage-dashboard.js");
const enrollmentId = "123e4567-e89b-12d3-a456-426614174000";
const topicId = "223e4567-e89b-12d3-a456-426614174000";
const sourceId = "323e4567-e89b-12d3-a456-426614174000";
const associationId = "423e4567-e89b-12d3-a456-426614174000";
const chunkId = "523e4567-e89b-12d3-a456-426614174000";

function coverage(overrides = {}) {
  return { enrollment_id: enrollmentId, disclosure: "source_coverage_not_mastery", numerator: 1, denominator: 2, percentage: 50, provisional: false, warning: null, topics: [
    { topic_id: topicId, position: 0, title: "Graph traversal", state: "covered", reason_codes: [], guidance: { recommended_source_kinds: ["pdf"], source_intake_url: `/sources/intake?enrollment_id=${enrollmentId}&topic_id=${topicId}` }, confirmed_sources: [{ id: associationId, source_id: sourceId, source_title: "Lecture notes", source_status: "ready", status: "confirmed", method: "deterministic", evidence_strength: 1, reason_code: "user_confirmed", stale: false, stale_reason: null, evidence: [{ chunk_id: chunkId, citation: "Lecture 4 §2", location: "page 8", excerpt: "Breadth-first traversal uses a queue." }] }], proposed_sources: [] },
    { topic_id: "623e4567-e89b-12d3-a456-426614174000", position: 1, title: "Dynamic programming", state: "missing", reason_codes: ["source_processing", "source_chunks_changed"], guidance: { recommended_source_kinds: ["pdf", "markdown"], source_intake_url: `/sources/intake?enrollment_id=${enrollmentId}&topic_id=623e4567-e89b-12d3-a456-426614174000` }, confirmed_sources: [], proposed_sources: [{ id: "923e4567-e89b-12d3-a456-426614174000", source_id: sourceId, source_title: "Old lecture notes", source_status: "ready", status: "proposed", method: "deterministic", evidence_strength: 0.75, reason_code: "meaningful_title_overlap", stale: true, stale_reason: "source_chunks_changed", evidence: [{ chunk_id: chunkId, citation: "Old notes §1", location: "page 2", excerpt: "An older matching excerpt." }] }] }
  ], ...overrides };
}
function learningMetrics(overrides = {}) {
  return {
    enrollment_id: enrollmentId,
    source_coverage: { authoritative: true, numerator: 1, denominator: 2, percentage: 50, reason_code: null, warning: null, covered_topics: [], missing_topics: [], review_topics: [], stale_topics: [] },
    recall: { correct_attempts: 4, attempt_count: 6, percentage: 66.67, last_evidence_at: "2025-07-24T12:00:00Z", reason_code: null, warning: null, topics: [{ topic_id: topicId, position: 0, title: "Graph traversal", correct_attempts: 1, attempt_count: 2, percentage: null, last_evidence_at: "2025-07-20T12:00:00Z", reason_code: "insufficient_attempts", warning: "At least 3 recent attempts are required for a recall percentage." }] },
    activity: { attempt_count: 6, cards_reviewed: 4, session_count: null, source_uploads: 2, source_changes: 1 },
    methodology: { coverage_formula: "confirmed topics / canonical topics", recall_formula: "correct approved-card attempts / approved-card attempts", activity_formula: "independent event counts", window_start: "2025-06-25T12:00:00Z", window_end: "2025-07-25T12:00:00Z", rolling_window_days: 30, minimum_attempts_per_topic: 3, minimum_attempts_overall: 5, freshness_cutoff: "2025-06-25T12:00:00Z", rating_semantics: { Again: false, Hard: true, Good: true, Easy: true }, exclusions: ["draft and unapproved-card attempts"], disclosures: ["source_coverage_not_mastery", "self_reported_recall_not_mastery"] },
    ...overrides,
  };
}
const candidates = [{ id: sourceId, title: "Lecture notes", source_type: "pdf", state: "ready", import_error: null, attachment: "enrollment", eligible: true }, { id: "723e4567-e89b-12d3-a456-426614174000", title: "Scanning", source_type: "pdf", state: "processing", import_error: null, attachment: "enrollment", eligible: true }, { id: "823e4567-e89b-12d3-a456-426614174000", title: "Broken", source_type: "pdf", state: "failed", import_error: "Could not parse", attachment: "unscoped", eligible: true }];
const chunks = [{ chunk_id: chunkId, citation: "Lecture 4 §2", location: "page 8", excerpt: "Breadth-first traversal uses a queue.", relevance: 1, rank: 1 }];

async function mount(page, handler, query = "", metricsResponse = { body: learningMetrics() }) {
  await page.route("**/api/curriculum", async route => {
    const request = route.request().postDataJSON();
    const response = request.action === "metrics.get" ? metricsResponse : await handler(request);
    await route.fulfill({ status: response.status || 200, contentType: "application/json", body: JSON.stringify(response.body) });
  });
  await page.goto("/login" + query);
  const styles = await page.locator("style").allTextContents();
  await page.setContent(`<style>${styles.join("\n")}</style><main class="coverage-candidates" data-coverage-dashboard data-enrollment-id="${enrollmentId}" data-demo="false"><div role="note"><strong>Source coverage, not mastery.</strong></div><strong data-coverage-metric></strong><span data-coverage-percentage></span><div data-coverage-warning hidden tabindex="-1"></div><p data-coverage-status role="status" tabindex="-1"></p><button data-recompute>Recompute proposals</button><div data-topic-table></div><div data-candidate-list></div><form data-manual-association><fieldset><select name="topic_id"><option value="">Select a topic</option></select><select name="source_id"><option value="">Select a source</option></select><div data-evidence-options aria-live="polite"></div><button type="submit" disabled>Confirm manual evidence</button></fieldset></form><section data-recall-panel aria-busy="true"><div data-recall-content></div></section><section data-activity-panel aria-busy="true"><div data-activity-content></div></section><details data-methodology><summary>Methodology and metric details</summary><div data-methodology-content></div></details></main>`);
  await page.addScriptTag({ path: asset });
}

test("confirmed-only metric, citations, missing reasons, candidate states and manual mapping", async ({ page }) => {
  const requests = [];
  await mount(page, async request => { requests.push(request); if (request.action === "coverage.get") return { body: coverage() }; if (request.action === "candidates.list") return { body: candidates }; if (request.action === "chunks.list") return { body: chunks }; return { body: {} }; });
  await expect(page.locator("[data-coverage-metric]")).toHaveText("1 / 2 topics");
  await expect(page.locator("[data-coverage-percentage]")).toHaveText("50%");
  await expect(page.getByText("Source coverage, not mastery.")).toBeVisible();
  await expect(page.getByText("Lecture 4 §2 · page 8")).toBeVisible();
  await expect(page.getByText(/still being processed/)).toBeVisible();
  await expect(page.getByText(/Stale evidence: The source content changed/)).toBeVisible();
  await expect(page.getByText("Status: processing", { exact: false })).toBeVisible();
  await expect(page.getByText("Status: failed", { exact: false })).toBeVisible();
  await page.locator('select[name="topic_id"]').selectOption(topicId);
  await page.locator('select[name="source_id"]').selectOption(sourceId);
  await expect(page.locator("[data-evidence-options]").getByText("Breadth-first traversal uses a queue.")).toBeVisible();
  const checkbox = page.getByRole("checkbox", { name: /Lecture 4 §2/ });
  const checkboxBox = await checkbox.boundingBox();
  expect(checkboxBox.width).toBeLessThan(32);
  await checkbox.check();
  await page.getByRole("button", { name: "Confirm manual evidence" }).click();
  await expect.poll(() => requests.some(request => request.action === "association.manual")).toBeTruthy();
});

test("learning metrics keep source coverage, 30-day self-reported recall, nulls, and activity distinct", async ({ page }) => {
  await mount(page, async request => request.action === "coverage.get" ? { body: coverage() } : { body: candidates });
  await expect(page.locator("[data-coverage-metric]")).toHaveText("1 / 2 topics");
  await expect(page.locator("[data-recall-content]")).toContainText("30-day rolling UTC window");
  await expect(page.locator("[data-recall-content]")).toContainText("66.67% weighted overall");
  await expect(page.locator("[data-recall-content]")).toContainText("At least 3 recent attempts are required");
  await expect(page.locator("[data-activity-content]")).toContainText("Not persisted");
  await expect(page.locator("[data-activity-content]")).toContainText("Sources uploaded");
  await page.locator("[data-methodology] summary").click();
  await expect(page.locator("[data-methodology-content]")).toContainText("Recall thresholds");
  await expect(page.locator("[data-methodology-content]")).toContainText("draft and unapproved-card attempts");
});

test("learning-metrics failure is scoped and leaves source coverage usable", async ({ page }) => {
  await mount(page, async request => request.action === "coverage.get" ? { body: coverage() } : { body: candidates }, "", { status: 503, body: { detail: "Unavailable" } });
  await expect(page.locator("[data-coverage-metric]")).toHaveText("1 / 2 topics");
  await expect(page.getByRole("button", { name: "Retry learning metrics" })).toBeVisible();
  await expect(page.locator("[data-activity-content]")).toContainText("Activity volume unavailable");
  await expect(page.getByRole("button", { name: "Recompute proposals" })).toBeEnabled();
});

test("manual evidence selector shows loading, retryable error, and truthful empty states", async ({ page }) => {
  let chunkReads = 0;
  await mount(page, async request => {
    if (request.action === "coverage.get") return { body: coverage() };
    if (request.action === "candidates.list") return { body: candidates };
    if (request.action === "chunks.list") {
      chunkReads += 1;
      await new Promise(resolve => setTimeout(resolve, 100));
      return chunkReads === 1 ? { status: 503, body: { detail: "Unavailable" } } : { body: [] };
    }
    return { body: {} };
  });
  await page.locator('select[name="topic_id"]').selectOption(topicId);
  await page.locator('select[name="source_id"]').selectOption(sourceId);
  await expect(page.getByText("Loading evidence excerpts…")).toBeVisible();
  await expect(page.getByRole("button", { name: "Retry evidence excerpts" })).toBeVisible();
  await page.getByRole("button", { name: "Retry evidence excerpts" }).click();
  await expect(page.getByText("No selectable evidence chunks are available for this topic and source.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Confirm manual evidence" })).toBeDisabled();
});

test("provisional denominator hides percentage and proposal review remains explicit", async ({ page }) => {
  const proposal = { ...coverage().topics[0].confirmed_sources[0], status: "proposed", reason_code: "meaningful_title_overlap" };
  let current = coverage({ numerator: 0, percentage: null, provisional: true, warning: "Topic list is provisional; no authoritative coverage percentage is available.", topics: [{ ...coverage().topics[0], state: "review", confirmed_sources: [], proposed_sources: [proposal], reason_codes: ["proposal_requires_review"] }] });
  const requests = [];
  await mount(page, async request => { requests.push(request); if (request.action === "coverage.get") return { body: current }; if (request.action === "candidates.list") return { body: candidates }; if (request.action === "association.decide") { current = coverage(); return { body: proposal }; } return { body: {} }; });
  await expect(page.locator("[data-coverage-percentage]")).toBeEmpty();
  await expect(page.locator("[data-coverage-warning]")).toContainText("provisional");
  await page.getByRole("button", { name: "Confirm evidence" }).focus();
  await page.keyboard.press("Enter");
  await expect.poll(() => requests.some(request => request.action === "association.decide" && request.payload.decision === "confirm")).toBeTruthy();
});

test("explicit synthetic dashboard is responsive, labelled and mutation-disabled", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 667 });
  await page.goto(`/learning/${enrollmentId}?mock=1`);
  await expect(page.getByRole("heading", { name: "CS2040S — Data Structures and Algorithms" })).toBeVisible();
  await expect(page.getByText("Source coverage, not mastery.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Recompute proposals" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Confirm manual evidence" })).toBeDisabled();
  await expect(page.locator("[data-recall-content]")).toContainText("30-day rolling UTC window");
  await expect(page.locator("[data-activity-content]")).toContainText("Not persisted");
  await page.getByRole("link", { name: "Add source for this topic" }).focus();
  await expect(page.getByRole("link", { name: "Add source for this topic" })).toBeFocused();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("source guidance URL preserves enrollment and topic context", async ({ page }) => {
  await page.goto(`/sources/intake?enrollment_id=${enrollmentId}&topic_id=${topicId}&mock=1`);
  const current = new URL(page.url());
  expect(current.pathname).toBe("/sources");
  expect(current.searchParams.get("enrollment_id")).toBe(enrollmentId);
  expect(current.searchParams.get("topic_id")).toBe(topicId);
  await expect(page.getByText("Source needed for topic: Synthetic topic fixture")).toBeVisible();
  await expect(page.getByText(/Importing never claims coverage automatically/)).toBeVisible();
});

test("recompute failure preserves rendered metric without claiming a commit", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 667 });
  await mount(page, async request => request.action === "coverage.get" ? { body: coverage() } : request.action === "candidates.list" ? { body: candidates } : { status: 503, body: { detail: "Unavailable" } });
  await page.getByRole("button", { name: "Recompute proposals" }).focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("status")).toContainText("existing decisions were not changed");
  await expect(page.getByRole("status")).not.toContainText("committed");
  await expect(page.locator("[data-coverage-metric]")).toHaveText("1 / 2 topics");
  await expect(page.getByRole("status")).toBeFocused();
});

test("coverage and candidates load independently with scoped retry states", async ({ page }) => {
  await mount(page, async request => request.action === "coverage.get" ? { body: coverage() } : { status: 503, body: { detail: "Unavailable" } });
  await expect(page.locator("[data-coverage-metric]")).toHaveText("1 / 2 topics");
  await expect(page.getByRole("button", { name: "Retry candidate sources" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Recompute proposals" })).toBeDisabled();

  await mount(page, async request => request.action === "candidates.list" ? { body: candidates } : { status: 503, body: { detail: "Unavailable" } });
  await expect(page.locator("[data-candidate-list]").getByText("Lecture notes", { exact: true })).toBeVisible();
  await expect(page.getByRole("status")).toContainText("coverage service is unavailable");
  await expect(page.locator("[data-coverage-metric]")).toBeEmpty();
});

test("a successful mutation followed by refresh failure reports committed and only retries reads", async ({ page }) => {
  const proposal = { ...coverage().topics[0].confirmed_sources[0], status: "proposed", reason_code: "meaningful_title_overlap" };
  const proposalCoverage = coverage({ numerator: 0, topics: [{ ...coverage().topics[0], state: "review", confirmed_sources: [], proposed_sources: [proposal] }] });
  let coverageReads = 0;
  let decisions = 0;
  await mount(page, async request => {
    if (request.action === "coverage.get") return ++coverageReads === 1 ? { body: proposalCoverage } : { status: 503, body: { detail: "Unavailable" } };
    if (request.action === "candidates.list") return { body: candidates };
    if (request.action === "association.decide") { decisions += 1; return { body: proposal }; }
    return { body: {} };
  });
  await page.getByRole("button", { name: "Confirm evidence" }).click();
  await expect(page.getByRole("status")).toContainText("Evidence confirmed. Saved, but the latest dashboard could not reload.");
  await expect(page.getByRole("button", { name: "Retry refresh" })).toBeVisible();
  await expect(page.getByRole("status")).not.toContainText("not changed");
  await page.getByRole("button", { name: "Retry refresh" }).click();
  await expect.poll(() => coverageReads).toBe(3);
  expect(decisions).toBe(1);
});
