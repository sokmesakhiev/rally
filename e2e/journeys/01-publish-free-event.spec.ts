import { test, expect } from "../fixtures/rally";

/**
 * Journey 1 — an organizer creates an event and publishes it on the free
 * plan, and a stranger can then find it.
 *
 * Crosses: event creation → the plan gate → `Event.publicly_visible`.
 *
 * **The one journey that builds its event through the UI.** Every other
 * journey seeds one (D6), because setup clicking is slow and fails for
 * reasons unrelated to the thing under test. Here the form *is* the thing
 * under test, so it gets driven for real — including the part where the
 * capacity comes from the plan rather than from anything the organizer typed
 * into the form, which is the seam this journey exists to cover.
 */

// A fixed future date rather than `new Date()` arithmetic: the assertion
// below is about publishing, not about date handling, and a test whose input
// drifts every day is a test that eventually fails on a boundary nobody
// chose. Far enough out that it stays in the future for years.
const START_AT = "2030-04-14T06:00";

test("an organizer publishes a free event and it reaches the catalogue", async ({
  rally,
  page,
}) => {
  const world = await rally.reset("organizer");
  await rally.signIn(world.users.organizer!);

  // ── Create the draft ───────────────────────────────────────────────────
  await page.goto("/events/new");

  // One organization is seeded on purpose, so "Presented by" is a label
  // rather than a dropdown — see the scenario's comment.
  await expect(page.getByText("Phnom Penh Runners")).toBeVisible();

  await page.locator("#title").fill("Sunrise 10K");
  await page
    .locator("#desc")
    .fill("A flat, fast morning route along the river.");
  // The location field has a generated id (LocationPicker uses useId), and
  // renders as a plain input because VITE_GOOGLE_MAPS_API_KEY isn't set in
  // this environment — which is itself worth exercising, since that fallback
  // is what any developer without a Google Cloud project sees.
  await page.getByLabel("Location").fill("Riverside, Phnom Penh");
  await page.locator("#start").fill(START_AT);

  await page.getByRole("button", { name: "Save draft" }).click();

  // Lands on the management page for the new event.
  await expect(page).toHaveURL(/\/dashboard\/events\//);
  await expect(
    page.getByRole("heading", { name: "Sunrise 10K" }),
  ).toBeVisible();
  const manageUrl = page.url();

  // ── Publish on the free plan ───────────────────────────────────────────
  await expect(page.getByText("Publish this event")).toBeVisible();

  // The plan cards are buttons whose accessible name starts with the plan
  // label and continues with the price and capacity ("Free Free Up to 20
  // people"), so anchor on the start rather than matching the whole string —
  // the price formatting is not what this journey is about.
  await page.getByRole("button", { name: /^Free/ }).click();

  // The free tier publishes immediately: no EventPlanPayment to poll, no
  // gateway involved. That branch is exactly why journey 2 exists separately.
  //
  // Asserted on the *durable* state, not on the panel's "Event published!"
  // confirmation — and that distinction cost a run to learn. The confirmation
  // is rendered by `PlanPaymentPanel`, whose `onPublished` callback
  // simultaneously invalidates the event query; the parent then re-renders
  // with `ev.is_published` true, which unmounts the whole publish section
  // including the message. So the success text exists only inside a race it
  // frequently loses. "Unpublish" and the current-plan line are what a person
  // would still see a minute later.
  await expect(page.getByRole("button", { name: "Unpublish" })).toBeVisible();
  await expect(
    page.getByText("You're on the free plan — up to 20 people."),
  ).toBeVisible();

  // ── A stranger can find it ─────────────────────────────────────────────
  //
  // Signed out, because `Event.publicly_visible` is the scope that decides
  // this and an authenticated organizer sees their own drafts by other
  // routes. The catalogue is the assertion that matters: this is what makes
  // publishing worth paying for.
  await rally.signOut();
  await page.goto("/events");
  await expect(page.getByText("Sunrise 10K")).toBeVisible();

  // And the event page itself is readable by someone with no account.
  await page.getByText("Sunrise 10K").first().click();
  await expect(page).toHaveURL(/\/events\/[0-9a-f-]+$/);

  // Capacity came from the plan, not from the form — the form says so in as
  // many words ("Registrant capacity isn't set here"). 20 is Event::PLANS'
  // free tier. If this number ever disagrees with the backend, the plan gate
  // has stopped doing the one thing it is for.
  await expect(page.getByText(/0 \/ 20 registered/)).toBeVisible();

  // Belt and braces via the API, because the rendered string above could in
  // principle be right for the wrong reason.
  const response = await rally.api.get(
    `/api/v1/events/${manageUrl.split("/").pop()}`,
  );
  const { event } = await response.json();
  expect(event.is_published).toBe(true);
  expect(event.capacity).toBe(20);
  expect(event.price_cents).toBe(0);
});
