const { test, expect } = require("@playwright/test");
const path = require("node:path");

const asset = path.join(__dirname, "../../public/curriculum.js");
const appAsset = path.join(__dirname, "../../public/app.js");
const enrollmentId = "123e4567-e89b-12d3-a456-426614174000";
const revisionId = "223e4567-e89b-12d3-a456-426614174000";

async function mount(page, handler) {
  await page.route("**/api/curriculum", async (route) => {
    const request = route.request();
    const body = request.postDataJSON();
    const response = await handler(body);
    await route.fulfill({ status: response.status || 200, contentType: "application/json", body: JSON.stringify(response.body) });
  });
  await page.goto("/login");
  await page.setContent(`
    <main><form data-module-import novalidate><fieldset><label><input type="radio" name="import_method" value="share_url" checked> NUSMods share link</label><label><input type="radio" name="import_method" value="manual_codes"> Module codes</label><label data-share-field>NUSMods share URL<input name="share_url"></label><label data-codes-field hidden>Module codes<input name="module_codes"></label><label>Academic year<select name="academic_year"><option value="2025-2026">2025–2026</option></select></label><label data-semester-field hidden>Semester<select name="semester"><option value="1">Semester 1</option></select></label><button type="submit">Import modules</button></fieldset><p class="cp-form-status" data-import-status role="status" tabindex="-1"></p></form>
    <section data-import-preview hidden aria-live="polite" tabindex="-1"></section></main>`);
  await page.addScriptTag({ path: asset });
}

const preview = {
  id: revisionId, academic_year: "2025-2026", semester: 1, import_method: "share_url",
  reconciliation: { added: ["CS2040S"], unchanged: ["MA1521"], removed: ["CS1010S"], ambiguous: [] },
  items: [
    { code: "CS2040S", title: "Data Structures and Algorithms", available: true, disposition: "import", provider_version: "2025-2026", source_url: "https://api.nusmods.com/module.json", fetched_at: "2025-07-24T10:30:00Z", payload_sha256: "abc123" },
    { code: "XX0000", title: "Unavailable module", available: false, disposition: "not_found", provider_version: null, source_url: null, fetched_at: null, payload_sha256: null },
  ],
};

test("validation, preview selection, explicit archive, and confirmation are bounded", async ({ page }) => {
  const requests = [];
  await mount(page, async (body) => {
    requests.push(body);
    if (body.action === "import.preview") return { body: preview };
    return { body: { preview_id: revisionId, items: [{ code: "CS2040S", status: "imported", enrollment_id: enrollmentId }] } };
  });
  await page.getByLabel("NUSMods share URL").last().fill("https://example.com/not-supported");
  await page.getByRole("button", { name: "Import modules" }).click();
  await expect(page.getByRole("status")).toContainText("complete HTTPS NUSMods");
  expect(requests).toHaveLength(0);

  await page.getByLabel("NUSMods share URL").last().fill("https://nusmods.com/timetable/sem-1/share?CS2040S=LEC:1");
  await page.getByRole("button", { name: "Import modules" }).click();
  const availableCard = page.locator(".cp-preview-card").filter({ hasText: "Data Structures and Algorithms" });
  const unavailableCard = page.locator(".cp-preview-card").filter({ hasText: "Unavailable module" });
  await expect(availableCard.getByText("CS2040S", { exact: true })).toBeVisible();
  await expect(availableCard.getByText("Data Structures and Algorithms", { exact: true })).toBeVisible();
  await expect(unavailableCard.getByText("XX0000", { exact: true })).toBeVisible();
  await expect(page.locator('input[value="XX0000"]')).toBeDisabled();
  await page.getByLabel("Archive CS1010S").check();
  await expect(page.locator("[data-commit-import]")).toHaveText("Import 1 module and archive 1 module");
  await expect(page.locator("[data-commit-import]")).toHaveClass(/cp-btn-danger/);
  const refresh = page.waitForRequest((request) => new URL(request.url()).pathname === "/dashboard");
  await page.locator("[data-commit-import]").click();
  await expect(page.getByRole("status")).toContainText("Modules imported");
  expect(requests.at(-1).payload).toEqual({ selected_codes: ["CS2040S"], archive_codes: ["CS1010S"] });
  expect(new URL((await refresh).url()).searchParams.get("import")).toBe("success");
});

test("partial NUSMods imports retain successes and use a distinct result banner", async ({ page }) => {
  await mount(page, async (body) => body.action === "import.preview" ? { body: preview } : { body: { items: [{ code: "CS2040S", status: "imported" }, { code: "XX0000", status: "not_found" }] } });
  await page.getByLabel("NUSMods share URL").last().fill("https://nusmods.com/timetable/sem-1/share?CS2040S=LEC:1");
  await page.getByRole("button", { name: "Import modules" }).click();
  const refresh = page.waitForRequest((request) => new URL(request.url()).pathname === "/dashboard");
  await page.locator("[data-commit-import]").click();
  await expect(page.getByRole("status")).toContainText("Some modules still need attention");
  expect(new URL((await refresh).url()).searchParams.get("import")).toBe("partial");

  await page.goto("/dashboard?mock=1&import=partial");
  await expect(page.getByText("Some modules need attention.", { exact: true })).toBeVisible();
  await page.goto("/dashboard?mock=1&import=success");
  await expect(page.getByText("Modules imported.", { exact: true })).toBeVisible();
});

test("confirmation rejects an empty import decision", async ({ page }) => {
  const requests = [];
  const unavailable = {
    ...preview,
    reconciliation: { added: [], unchanged: [], removed: [], ambiguous: ["XX0000"] },
    items: [preview.items[1]],
  };
  await mount(page, async (body) => {
    requests.push(body);
    return { body: unavailable };
  });
  await page.getByLabel("NUSMods share URL").last().fill("https://nusmods.com/timetable/sem-1/share?XX0000=LEC:1");
  await page.getByRole("button", { name: "Import modules" }).click();

  await page.locator("[data-commit-import]").click();

  await expect(page.getByRole("status")).toContainText("Choose at least one available module");
  expect(requests).toHaveLength(1);
});

test("uncertain confirmation failures direct users to reconcile before retrying", async ({ page }) => {
  await mount(page, async (body) => body.action === "import.preview" ? { body: preview } : { status: 503, body: { detail: "Provider unavailable" } });
  await page.getByLabel("NUSMods share URL").last().fill("https://nusmods.com/timetable/sem-1/share?CS2040S=LEC:1");
  await page.getByRole("button", { name: "Import modules" }).click();
  await page.locator("[data-commit-import]").click();
  await expect(page.getByRole("status")).toContainText("result could not be confirmed");
});

test("archive-only confirmation is labelled as a destructive archive", async ({ page }) => {
  const requests = [];
  await mount(page, async (body) => {
    requests.push(body);
    if (body.action === "import.preview") return { body: preview };
    return { body: { items: [{ code: "CS1010S", status: "archived" }] } };
  });
  await page.getByLabel("NUSMods share URL").fill("https://nusmods.com/timetable/sem-1/share?CS2040S=LEC:1");
  await page.getByRole("button", { name: "Import modules" }).click();
  await page.locator('input[value="CS2040S"]').uncheck();
  await page.getByLabel("Archive CS1010S").check();
  const confirm = page.locator("[data-commit-import]");
  await expect(confirm).toHaveText("Archive 1 module");
  await expect(confirm).toHaveClass(/cp-btn-danger/);
  await confirm.click();
  expect(requests.at(-1).payload).toEqual({ selected_codes: [], archive_codes: ["CS1010S"] });
});

test("confirmation enforces the combined 30-decision limit", async ({ page }) => {
  const requests = [];
  const codes = Array.from({ length: 30 }, (_, index) => `CS${String(index).padStart(4, "0")}`);
  const largePreview = {
    ...preview,
    reconciliation: { added: codes, unchanged: [], removed: ["MA1521"], ambiguous: [] },
    items: codes.map((code) => ({ ...preview.items[0], code, title: `Module ${code}` })),
  };
  await mount(page, async (body) => { requests.push(body); return { body: largePreview }; });
  await page.getByLabel("NUSMods share URL").fill("https://nusmods.com/timetable/sem-1/share?CS2040S=LEC:1");
  await page.getByRole("button", { name: "Import modules" }).click();
  await page.getByLabel("Archive MA1521").check();
  await page.locator("[data-commit-import]").click();
  await expect(page.getByRole("status")).toContainText("no more than 30 combined");
  expect(requests).toHaveLength(1);
});

test("mobile import controls remain keyboard reachable and labelled", async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 667 });
  await mount(page, async () => ({ body: preview }));
  await page.getByLabel("NUSMods share URL").fill("https://nusmods.com/timetable/sem-1/share?CS2040S=LEC:1");
  await page.getByRole("button", { name: "Import modules" }).focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("[data-import-preview]")).toBeVisible();
  await expect(page.locator("[data-commit-import]")).toBeVisible();
});

test("module-scoped link intake stays a bookmark and retains enrollment identity", async ({ page }) => {
  let sourceRequest;
  await page.route("**/api/sources/import", async (route) => {
    sourceRequest = route.request().postDataJSON();
    await route.fulfill({ status: 201, contentType: "application/json", body: JSON.stringify({ import_status: "saved", duplicate: false, source: { id: "source-1" } }) });
  });
  await page.route("**/sources?*", (route) => route.fulfill({ status: 200, contentType: "text/html", body: "<main>Source library</main>" }));
  await page.goto(`/login?module_scope=${enrollmentId}`);
  await page.setContent(`<main>
    <input id="cp-source-search"><select id="cp-source-format"><option value="">All</option></select><span id="cp-source-count"></span><h2 id="cp-source-heading"></h2><div id="cp-source-empty"></div><section id="cp-document-grid"></section>
    <button id="cp-add-source" type="button">Add source</button>
    <div id="cp-add-source-modal" hidden><section><button type="button" data-close-source-modal>Close</button>
      <button type="button" data-source-mode="upload">Upload files</button><button type="button" data-source-mode="link">Add link</button><button type="button" data-source-mode="paste">Paste text</button>
      <form id="cp-add-source-form" action="/api/sources/import"><input name="mode" value="upload"><div data-source-panel="upload"></div><div data-source-panel="link" hidden></div><div data-source-panel="paste" hidden></div>
        <input id="cp-new-source-title" value="Reference"><input id="cp-new-source-url" value="https://example.test/notes"><input id="cp-new-source-module" value="CS2040S"><button type="submit">Import source</button><p class="cp-form-status"></p>
      </form></section></div></main>`);
  await page.addScriptTag({ path: appAsset });
  await page.getByRole("button", { name: "Add source" }).click();
  await page.getByRole("button", { name: "Add link" }).click();
  await page.getByRole("button", { name: "Import source" }).click();
  await expect.poll(() => sourceRequest).toBeTruthy();
  expect(sourceRequest).toMatchObject({ enrollment_id: enrollmentId, mode: "link", source_type: "link" });
  await expect.poll(() => new URL(page.url()).searchParams.get("import")).toBe("saved");
  expect(new URL(page.url()).searchParams.get("module_scope")).toBe(enrollmentId);
});
