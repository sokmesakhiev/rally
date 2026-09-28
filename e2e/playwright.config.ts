import { defineConfig, devices } from "@playwright/test";

/**
 * The end-to-end suite. See docs/e2e-testing-design.md for why it exists and
 * what it does and doesn't cover.
 *
 * Three servers, started here so that `npm test` is the whole instruction:
 *
 *   :3002  the fake PayWay gateway (support/fake-payway)
 *   :3000  Rails, in the `e2e` environment, against the rally_e2e database
 *   :8080  Vite, serving the SPA and pointed at :3000
 *
 * Started in that order because each depends on the one before: Rails reads
 * the gateway's address at boot, and the SPA is useless without the API.
 * Playwright starts `webServer` entries in parallel but waits for every
 * `url` before the first test, so the ordering that matters — all three up
 * before anything runs — is guaranteed regardless.
 */

import { E2E_URLS, RAILS_PORT, VITE_PORT, PAYWAY_PORT } from "./urls";

const { rails: railsUrl, app: appUrl, payway: paywayUrl } = E2E_URLS;

export default defineConfig({
  testDir: "./journeys",

  // Serially, deliberately. Every journey resets the *same* database, so two
  // running at once would truncate each other's world mid-test — and the
  // failure would look like flakiness rather than like the design decision
  // that caused it. Parallelism here would need a database per worker, which
  // is a real option if the suite ever outgrows its five-minute budget, and
  // is not worth the machinery for six tests.
  workers: 1,
  fullyParallel: false,

  // A `.only` left in a file passes locally and silently skips everything
  // else in the nightly run — the exact failure mode D3 exists to avoid.
  forbidOnly: !!process.env.CI,

  // One retry, and traces kept from it. E2E failures are frequently
  // un-reproducible on a second run; a trace with DOM snapshots at every step
  // is the difference between diagnosing one and shrugging at it. Retrying
  // more than once would start hiding real intermittent bugs.
  retries: process.env.CI ? 1 : 0,

  reporter: process.env.CI
    ? [["list"], ["html", { open: "never" }], ["github"]]
    : [["list"], ["html", { open: "never" }]],

  // Generous, because a cold Rails boot plus a Vite dep optimisation pass is
  // genuinely slow the first time. This is the ceiling on a whole test, not a
  // sleep anybody waits for on the happy path.
  timeout: 90_000,
  expect: { timeout: 15_000 },

  use: {
    baseURL: appUrl,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",

    // Off, and this is the rule that keeps the suite honest: an assertion
    // should wait for the app to be ready, never for the clock. Any journey
    // that needs `waitForTimeout` is a bug report about the app, not a test
    // to patch.
    actionTimeout: 15_000,
  },

  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
    // Open question 1 in the design doc: Firefox and WebKit multiply the
    // runtime for a class of bug this app is unlikely to hit. Khmer font
    // rendering is the one genuine unknown, and it wants a screenshot test
    // rather than the whole suite run three times.
  ],

  webServer: [
    {
      name: "fake-payway",
      command: "node support/fake-payway/server.mjs",
      env: { PORT: String(PAYWAY_PORT) },
      url: `${paywayUrl}/__health`,
      reuseExistingServer: !process.env.CI,
      stdout: "pipe",
      stderr: "pipe",
    },
    {
      // `db:prepare` first, every time: it creates and migrates rally_e2e
      // when it doesn't exist and is close to free when it's current. The
      // alternative is a documented setup step, and a documented setup step
      // is one somebody forgets — the failure being a stack of confusing
      // PG::UndefinedTable errors rather than anything that names the cause.
      // Same reasoning as bin/docker-entrypoint doing this on container boot.
      name: "rails",
      command: `bin/rails db:prepare && bin/rails server -p ${RAILS_PORT} -b 127.0.0.1`,
      cwd: "../backend",
      env: {
        RAILS_ENV: "e2e",
        // Set as well as passed with -p, deliberately. config/puma.rb binds
        // to `ENV.fetch("PORT", 3000)`, so a developer with PORT exported in
        // their shell — not rare — would get a server on the wrong port and
        // a startup timeout that names nothing. Stating it here makes the
        // config file and the flag agree whatever the precedence is.
        PORT: String(RAILS_PORT),
        // Where Rally tells the gateway to send its webhook, and where the
        // SPA is allowed to call from (config/initializers/cors.rb reads
        // FRONTEND_URL outside development).
        BACKEND_URL: railsUrl,
        FRONTEND_URL: appUrl,
        ABA_PAYWAY_BASE_URL: paywayUrl,
        // The stub doesn't verify the HMAC — it holds no real key. These
        // only have to be non-blank to satisfy
        // AbaPayway::Client#ensure_configured!, and they are written to look
        // like what they are.
        ABA_PAYWAY_MERCHANT_ID: "e2e_fake_merchant",
        ABA_PAYWAY_API_KEY: "e2e_fake_api_key",
        RAILS_LOG_LEVEL: process.env.E2E_RAILS_LOG_LEVEL ?? "warn",
      },
      url: `${railsUrl}/up`,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
      stdout: "pipe",
      stderr: "pipe",
    },
    {
      name: "vite",
      command: `npm run dev -- --port ${VITE_PORT} --strictPort`,
      cwd: "../frontend",
      env: {
        VITE_API_URL: railsUrl,
        VITE_BASE_URL: appUrl,
      },
      url: appUrl,
      reuseExistingServer: !process.env.CI,
      timeout: 120_000,
      stdout: "pipe",
      stderr: "pipe",
    },
  ],
});
