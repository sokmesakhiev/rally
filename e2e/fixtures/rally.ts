import { test as base, expect, type APIRequestContext } from "@playwright/test";
import { E2E_URLS } from "../urls";

/**
 * The fixture every journey starts from.
 *
 * A test declares the world it needs and gets back the ids and credentials
 * that world contains — see docs/e2e-testing-design.md D6. The exception is
 * the journey under test: a registration journey registers through the UI, a
 * check-in journey seeds the registrations.
 */

export interface SeededUser {
  id: string;
  email: string;
  password: string;
  display_name: string | null;
}

export interface SeededEvent {
  id: string;
  title: string;
  /** Public event page. Navigate to what you were handed, don't build paths. */
  url: string;
  /** Organizer's management page for the same event. */
  manage_url: string;
  price_cents: number;
  capacity: number | null;
}

export interface SeededRegistration {
  id: string;
  bib_number?: string;
  email?: string;
  user_id?: string;
}

export interface Scenario {
  scenario: string;
  users: Record<string, SeededUser | undefined>;
  organizations?: Record<string, { id: string; name: string; slug: string }>;
  events?: Record<string, SeededEvent | undefined>;
  registrations?: Record<string, SeededRegistration | undefined>;
}

export interface GatewayTransaction {
  tran_id: string;
  amount: string;
  currency: string;
  status: "PENDING" | "APPROVED";
}

export interface Rally {
  /**
   * Truncates the database and seeds a named world. Also clears the fake
   * gateway, so a transaction id from a previous journey can't be paid twice.
   *
   * Scenario names live in backend/db/e2e_scenarios.rb; an unknown one comes
   * back as a 422 naming the ones that exist, rather than as a mystery.
   */
  reset(scenario?: string): Promise<Scenario>;

  /** Signs in through the UI and waits for the dashboard. */
  signIn(user: SeededUser): Promise<void>;

  /** Clears the stored JWT without a round trip through the header menu. */
  signOut(): Promise<void>;

  /** Everything the gateway has been asked to charge, newest first. */
  transactions(): Promise<GatewayTransaction[]>;

  /**
   * Stands in for a human paying a KHQR code: marks the transaction approved
   * at the gateway and makes it fire Rally's real webhook.
   *
   * Note what this does *not* do — it doesn't change any Rally state
   * directly. The webhook is only a trigger; Rally calls the gateway back to
   * ask what happened, and that round trip is the point of testing against a
   * stub rather than stubbing Rally's own code.
   */
  pay(tranId: string): Promise<void>;

  /**
   * Waits for Rally to start a payment, then settles it — for the common
   * case where the test just caused a QR to appear and has no id to name.
   *
   * Returns the transaction, so a journey can assert the amount Rally asked
   * for. Nothing in the UI shows that number before payment, which makes
   * this the only place a wrong charge could be caught.
   */
  payLatest(): Promise<GatewayTransaction>;

  /** For setup and assertions that have no business going through the UI. */
  api: APIRequestContext;

  /**
   * An API context authenticated as `user`.
   *
   * For the steps a journey needs to *happen* but isn't testing — a second
   * person acting while the browser stays signed in as the first. Driving
   * those through the UI would mean a second browser context and a sign-out/
   * sign-in dance per step, which is a lot of machinery to assert nothing.
   *
   * Use it for setup and for cross-checks, never to perform the action the
   * journey is named after: a journey whose subject happens over HTTP is
   * testing the API, and the API already has 1,700 request specs.
   */
  apiAs(user: SeededUser): Promise<APIRequestContext>;
}

export const test = base.extend<{ rally: Rally }>({
  rally: async ({ page, playwright }, use) => {
    const api = await playwright.request.newContext({
      baseURL: E2E_URLS.rails,
    });

    const transactions = async (): Promise<GatewayTransaction[]> => {
      const response = await api.get(`${E2E_URLS.payway}/__transactions`);
      expect(
        response.ok(),
        `could not read gateway transactions (${response.status()})`,
      ).toBeTruthy();
      return (await response.json()).transactions as GatewayTransaction[];
    };

    // Torn down alongside the main context at the end of the test. Tracked
    // rather than leaked: an undisposed request context keeps a connection
    // open, and Playwright reports that as a hang at the end of the run —
    // several tests away from whichever one created it.
    const extraContexts: APIRequestContext[] = [];

    const rally: Rally = {
      api,
      transactions,

      async apiAs(user) {
        const response = await api.post("/api/v1/auth/signin", {
          data: { email: user.email, password: user.password },
        });
        expect(
          response.ok(),
          `could not sign in as ${user.email} (${response.status()})`,
        ).toBeTruthy();

        const { token } = await response.json();
        const context = await playwright.request.newContext({
          baseURL: E2E_URLS.rails,
          extraHTTPHeaders: { Authorization: `Bearer ${token}` },
        });
        extraContexts.push(context);
        return context;
      },

      async reset(scenario = "empty") {
        // The gateway first. If the database were cleared first and this
        // threw, the next journey would start against a half-reset world —
        // the kind of state that produces one confusing failure somewhere
        // else entirely.
        const cleared = await api.post(`${E2E_URLS.payway}/__reset`, {
          data: {},
        });
        expect(
          cleared.ok(),
          `fake-payway did not reset (${cleared.status()}). Is it running on ${E2E_URLS.payway}?`,
        ).toBeTruthy();

        const response = await api.post("/api/e2e/reset", {
          data: { scenario },
        });
        expect(
          response.ok(),
          `reset to "${scenario}" failed with ${response.status()}: ${await response.text()}`,
        ).toBeTruthy();

        return (await response.json()) as Scenario;
      },

      async signIn(user) {
        await page.goto("/auth");
        await page.locator("#email-in").fill(user.email);
        await page.locator("#pw-in").fill(user.password);
        await page
          .getByRole("button", { name: "Sign in", exact: true })
          .click();
        await expect(page).toHaveURL(/\/dashboard/);
      },

      async signOut() {
        // localStorage is per-origin and throws on about:blank, so make sure
        // we're actually on the app before reaching for it — a journey that
        // switches user as its first act would otherwise fail with a
        // SecurityError that names nothing useful.
        if (!page.url().startsWith(E2E_URLS.app)) await page.goto("/");

        // Straight at the storage keys api-client.ts reads (TOKEN_KEY and
        // IMPERSONATION_TOKEN_KEY). Driving the header's avatar dropdown
        // instead would make every journey that switches user depend on the
        // shape of a menu none of them are testing.
        await page.evaluate(() => {
          window.localStorage.removeItem("rally_token");
          window.localStorage.removeItem("rally_impersonation_token");
        });
      },

      async pay(tranId) {
        const response = await api.post(`${E2E_URLS.payway}/__pay`, {
          data: { tran_id: tranId },
        });
        const body = await response.text();
        expect(
          response.ok(),
          `gateway could not settle ${tranId}: ${body}`,
        ).toBeTruthy();
      },

      async payLatest() {
        // Polling, not a sleep: the QR request is in flight when the test
        // gets here, and how long it takes is not something to guess at.
        await expect
          .poll(async () => (await transactions()).length, {
            message:
              "Rally never asked the gateway for a QR code. Either the payment " +
              "was not started, or ABA_PAYWAY_BASE_URL is not pointing at the stub.",
          })
          .toBeGreaterThan(0);

        const [latest] = await transactions();
        await rally.pay(latest.tran_id);
        return latest;
      },
    };

    await use(rally);
    for (const context of extraContexts) await context.dispose();
    await api.dispose();
  },
});

export { expect };
