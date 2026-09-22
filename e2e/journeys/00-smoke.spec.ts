import { test, expect } from "../fixtures/rally";
import { E2E_URLS } from "../urls";

/**
 * Phase 0's only test, and its whole job is to prove the foundation stands
 * up: three servers talking to each other, a database that can be reset over
 * HTTP, a seeded account that can actually sign in.
 *
 * Nothing here is a business journey. Those are Phases 1 and 2, and every one
 * of them is built on the four assertions below — which is why they're worth
 * having as their own file rather than folded into the first real journey,
 * where a failure would read as "publishing is broken" instead of "the
 * harness isn't up".
 */
test.describe("harness", () => {
  test("the three servers are up and talking to each other", async ({
    rally,
  }) => {
    const health = await rally.api.get("/up");
    expect(health.ok(), "Rails is not answering /up").toBeTruthy();

    const gateway = await rally.api.get(`${E2E_URLS.payway}/__health`);
    expect(
      gateway.ok(),
      "the fake PayWay gateway is not answering",
    ).toBeTruthy();
  });

  test("reset truncates and seeds a named world", async ({ rally }) => {
    const world = await rally.reset("participant");

    expect(world.scenario).toBe("participant");
    expect(world.users.participant?.email).toBe("participant@e2e.rally.test");
    expect(world.users.participant?.password).toBeTruthy();

    // The reset really truncated: the same scenario twice in a row must
    // succeed, which it cannot if the first run's user is still sitting
    // behind a unique index on email. This is the assertion that would catch
    // a reset that silently degraded into a no-op — the failure mode that
    // makes every later journey pass or fail depending on what ran before it.
    const second = await rally.reset("participant");
    expect(second.users.participant?.email).toBe("participant@e2e.rally.test");
    expect(second.users.participant?.id).not.toBe(world.users.participant?.id);
  });

  test("an unknown scenario says so instead of failing obscurely", async ({
    rally,
  }) => {
    const response = await rally.api.post("/api/e2e/reset", {
      data: { scenario: "no-such-world" },
    });

    expect(response.status()).toBe(422);
    expect(await response.text()).toContain("Unknown e2e scenario");
  });

  test("a seeded participant can sign in through the UI", async ({
    rally,
    page,
  }) => {
    const world = await rally.reset("participant");
    const participant = world.users.participant!;

    await rally.signIn(participant);

    // Proves the whole chain worked, not just that the URL changed: the SPA
    // reached the API cross-origin (so CORS is right), the JWT came back and
    // was stored, and an authenticated fetch succeeded. A redirect alone
    // would still happen if the dashboard then failed to load anything.
    await expect(page.getByText("Your dashboard")).toBeVisible();
  });
});
