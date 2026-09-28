import { test, expect } from "../fixtures/rally";

/**
 * Journey 2 — an organizer publishes on a paid plan: Rally asks the gateway
 * for a KHQR code, the payer settles it, the gateway fires Rally's webhook,
 * and the event goes live on its own.
 *
 * Crosses: plan payment → gateway → webhook → check-transaction →
 * `EventPlanPayment#mark_paid!` → publish.
 *
 * This is the highest-value test in the suite. Every link in that chain is
 * covered by a unit spec; none of those specs can tell you the chain is
 * *connected*, because each one stubs the link on either side of it.
 */

// Event::PLANS' "small" tier: 200 people, $100. Written out here rather than
// read from the API, deliberately — a test that derives its expectation from
// the same source as the code under test asserts nothing. If someone
// re-prices the plan, this fails and a human decides whether that was
// intended.
const PLAN_LABEL = "Small";
const PLAN_PRICE = "100.00";
const PLAN_CAPACITY = 200;

test("an organizer pays for a plan and the event publishes itself", async ({
  rally,
  page,
}) => {
  const world = await rally.reset("draft_event");
  const event = world.events!.main!;

  await rally.signIn(world.users.organizer!);
  await page.goto(event.manage_url);

  // A draft, and it says so.
  await expect(page.getByText("Publish this event")).toBeVisible();

  await page
    .getByRole("button", { name: new RegExp(`^${PLAN_LABEL}`) })
    .click();

  // ── Rally asks the gateway for a QR ────────────────────────────────────
  await expect(page.getByText("Scan with ABA Mobile")).toBeVisible();

  // Nothing is published yet. Asserted explicitly because the interesting
  // failure here is the optimistic one — an event that goes live on the
  // *request* for payment rather than on payment.
  const beforePayment = await rally.api.get(`/api/v1/events/${event.id}`);
  expect((await beforePayment.json()).event.is_published).toBe(false);

  // ── Somebody pays ──────────────────────────────────────────────────────
  const transaction = await rally.payLatest();

  // The amount Rally asked to charge. This is the only place it can be
  // checked: it's computed server-side from Event::PLANS (minus anything
  // already paid for this event) and never rendered before payment.
  expect(transaction.amount).toBe(PLAN_PRICE);
  expect(transaction.currency).toBe("USD");
  expect(transaction.tran_id).toMatch(/^pln/);

  // ── …and the event publishes itself ────────────────────────────────────
  //
  // Longer than the default expect timeout on purpose, and it is worth
  // knowing why rather than treating the number as a magic constant. Three
  // asynchronous hops stand between the click above and this text:
  //
  //   1. the gateway POSTs Rally's webhook, which only enqueues a job;
  //   2. the job runs (the :async adapter in this environment) and calls
  //      check-transaction back out to the gateway before changing anything;
  //   3. the panel is polling its own status endpoint every 4 seconds.
  //
  // Step 3 alone can account for most of the wait. This is not a sleep —
  // the assertion resolves as soon as the page reaches the state.
  //
  // And it is the *durable* state, not the panel's "Payment received — event
  // published!" line. That message and the query invalidation that unmounts
  // the whole publish section are triggered by the same effect, so the
  // confirmation lives inside a race it usually loses. See journey 1 for the
  // same trap and the same fix.
  await expect(page.getByRole("button", { name: "Unpublish" })).toBeVisible({
    timeout: 30_000,
  });
  await expect(
    page.getByText(`You're on the small plan — up to ${PLAN_CAPACITY} people.`),
  ).toBeVisible();

  const afterPayment = await rally.api.get(`/api/v1/events/${event.id}`);
  const published = (await afterPayment.json()).event;
  expect(published.is_published).toBe(true);
  // The plan set the capacity. An event that published without taking its
  // plan's capacity would sell more places than the organizer paid for.
  expect(published.capacity).toBe(PLAN_CAPACITY);

  // And the public catalogue has it, signed out — the same scope journey 1
  // checks, reached by the paid route this time.
  await rally.signOut();
  await page.goto("/events");
  await expect(page.getByText(event.title)).toBeVisible();
});
