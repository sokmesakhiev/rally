import { test, expect } from "../fixtures/rally";

/**
 * Journey 3 — a participant finds a paid race in the catalogue, registers,
 * pays by KHQR, and ends up holding a place.
 *
 * Crosses: the public catalogue → registration → capacity → payment →
 * webhook → `Registration#mark_paid_from_payment!`.
 *
 * The seam worth naming: **a registration row is written before the money
 * arrives.** That ordering is deliberate (it is why the capacity and
 * closing-registration validations are `on: :create` — see
 * `.claude/rules/registration-and-capacity.md`), and it means "registered"
 * and "paid" are two states, not one. This journey walks through both.
 */

test("a participant registers for a paid race and pays for it", async ({
  rally,
  page,
}) => {
  const world = await rally.reset("paid_event");
  const event = world.events!.main!;
  const participant = world.users.participant!;

  await rally.signIn(participant);

  // Arrive the way a real participant does — through the catalogue, not by
  // typing an id. The listing page is served by `Event.publicly_visible`,
  // so this is also the assertion that the event is genuinely public.
  await page.goto("/events");
  await page.getByText(event.title).first().click();
  await expect(page).toHaveURL(new RegExp(event.id));

  // ── Register ───────────────────────────────────────────────────────────
  await page.getByRole("button", { name: "Register" }).click();

  // A paid registration goes through a confirmation step before the charge,
  // by design: a typo'd contact or the wrong race caught here costs nothing,
  // and caught afterwards costs a refund.
  await expect(page.getByText("Confirm your registration")).toBeVisible();
  await page.getByRole("button", { name: "Confirm & register" }).click();

  // ── Registered, not yet paid ───────────────────────────────────────────
  await expect(page.getByText("Scan with ABA Mobile")).toBeVisible();

  // The row exists already. This is the state the ordering above creates,
  // and it is worth pinning: a change that deferred the row until payment
  // would break capacity counting in a way no unit spec would notice.
  const afterRegister = await rally.api.get(`/api/v1/events/${event.id}`);
  expect((await afterRegister.json()).event.registrations_count).toBe(1);

  // ── Pay ────────────────────────────────────────────────────────────────
  const transaction = await rally.payLatest();

  // The participant's payment carries the "rly" prefix; an organizer's
  // publish payment carries "pln". Two different flows through one gateway,
  // and conflating them is the mistake `.claude/rules/payments.md` opens by
  // warning about — so the journey checks it got the right one.
  expect(transaction.tran_id).toMatch(/^rly/);
  expect(transaction.amount).toBe("25.00");

  // Same three-hop wait as journey 2: webhook → job → check-transaction,
  // then the panel's own poll. Resolves as soon as the text lands.
  //
  // `exact: true` is not optional here: `eventDetail.toastPaid` reads "You're
  // registered! Add the event to your calendar.", so a substring match can
  // resolve to two elements and fail on strict mode instead of passing. It
  // only depends on whether the toast is still up when the assertion fires,
  // which is precisely the kind of timing coin-flip that makes a suite
  // untrustworthy.
  await expect(
    page.getByText("You're registered", { exact: true }),
  ).toBeVisible({ timeout: 30_000 });

  // ── And it stuck ───────────────────────────────────────────────────────
  //
  // Through the dashboard rather than the same page, because the interesting
  // failure is a payment that looks applied in the component that just
  // polled it and is not actually persisted.
  await page.goto("/dashboard");
  await expect(page.getByText(event.title)).toBeVisible();
  await expect(page.getByText("Paid").first()).toBeVisible();
});
