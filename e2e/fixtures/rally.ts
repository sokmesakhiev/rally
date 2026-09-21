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

export interface Scenario {
  scenario: string;
  users: Record<string, SeededUser | undefined>;
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

  /** For setup and assertions that have no business going through the UI. */
  api: APIRequestContext;
}

export const test = base.extend<{ rally: Rally }>({
  rally: async ({ page, playwright }, use) => {
    const api = await playwright.request.newContext({
      baseURL: E2E_URLS.rails,
    });

    const rally: Rally = {
      api,

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
    };

    await use(rally);
    await api.dispose();
  },
});

export { expect };
