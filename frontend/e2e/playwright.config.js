const { defineConfig } = require("@playwright/test");

const port = process.env.PLAYWRIGHT_PORT || "3101";
const baseURL = process.env.PLAYWRIGHT_BASE_URL || `http://127.0.0.1:${port}`;

module.exports = defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: process.env.CI ? [["line"], ["html", { open: "never" }]] : "line",
  use: {
    baseURL,
    browserName: "chromium",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  webServer: {
    command: `cd .. && WIKIBASE_MOCK_ENABLED=true WIKIBASE_BACKEND_URL=http://127.0.0.1:9 WIKIBASE_PUBLIC_ORIGIN=${baseURL} ./zig-out/bin/app --host 127.0.0.1 --port ${port} --no-dev --no-dotenv`,
    url: `${baseURL}/login`,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
