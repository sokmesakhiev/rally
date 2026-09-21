/**
 * Where the three servers live.
 *
 * Its own module rather than an export from playwright.config.ts, so that a
 * test importing an address doesn't pull the whole config — and its
 * `webServer` command strings — into the test process. One place decides the
 * ports; the config and the fixtures both read it.
 */
export const RAILS_PORT = Number(process.env.E2E_RAILS_PORT ?? 3000);
export const VITE_PORT = Number(process.env.E2E_VITE_PORT ?? 8080);
export const PAYWAY_PORT = Number(process.env.E2E_PAYWAY_PORT ?? 3002);

export const E2E_URLS = {
  rails: `http://localhost:${RAILS_PORT}`,
  app: `http://localhost:${VITE_PORT}`,
  payway: `http://127.0.0.1:${PAYWAY_PORT}`,
} as const;
