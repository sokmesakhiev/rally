import { test, expect } from "../fixtures/rally";

/**
 * Journey 4 — a race is full, someone queues, a place frees up, and the
 * queue turns into a registration.
 *
 * Crosses: capacity → `WaitlistEntry` → `Waitlists::PromoteNext` →
 * notification → the ordinary KHQR payment flow.
 *
 * That last hop is unique to this journey. A promotion on a paid race hands
 * someone a place they still owe money for, and nothing else in the suite
 * covers a registration that arrives already-created and then gets paid.
 *
 * Why this one is worth a browser: promotion happens *somewhere else*. The
 * person who joined the queue isn't on the page — isn't even in the app —
 * when their place arrives. Everything between the organizer's click and
 * that person's next page load is exactly the stretch a unit spec cannot
 * see, and `.claude/rules/registration-and-capacity.md` records that this
 * path was silently broken once already: every promotion on a closed event
 * raised, was swallowed by a rescue written for a different race, and left
 * people queueing forever with nothing logged.
 */

test("a freed place promotes the next person on the waitlist", async ({
  rally,
  page,
}) => {
  const world = await rally.reset("full_event");
  const event = world.events!.main!;
  const waiter = world.users.waiter!;

  // ── The race is full, so the page offers the queue ─────────────────────
  await rally.signIn(waiter);
  await page.goto(event.url);

  // "Full" and "closed" are different facts with different offers — a full
  // event offers the waitlist, a closed one offers nothing, because there is
  // nothing to wait for. Seeing the queue at all is the assertion.
  await expect(page.getByText("1 / 1 registered")).toBeVisible();
  await page.getByRole("button", { name: "Join waitlist" }).click();
  // `exact: true`, because the success toast reads "You're on the waitlist —
  // we'll email you if a spot opens up." and a substring match hits both it
  // and the panel heading — two elements, which is a strict-mode violation
  // rather than a pass. Anchoring on the heading is also the right choice on
  // its own terms: the toast disappears, the heading doesn't.
  await expect(
    page.getByText("You're on the waitlist", { exact: true }),
  ).toBeVisible();

  // ── A place frees up ───────────────────────────────────────────────────
  //
  // Over the API, not through the manage page, and that is a deliberate
  // compromise rather than a shortcut: the organizer's "remove participant"
  // control is an icon-only ghost button with no accessible name, so the
  // only way to click it is a selector tied to an SVG. Journey 4's subject
  // is what happens *after* a place frees up; hanging it on a brittle
  // locator would make it fail for a reason it isn't about.
  //
  // The unlabelled button is a real finding — see "Known gaps" in the README.
  const organizerApi = await rally.apiAs(world.users.organizer!);
  const removed = await organizerApi.delete(
    `/api/v1/registrations/${world.registrations!.holder!.id}`,
  );
  expect(
    removed.ok(),
    `could not free a place: ${removed.status()} ${await removed.text()}`,
  ).toBeTruthy();

  // ── The person who was queueing now has a place ────────────────────────
  //
  // **There is nothing to wait for**, and getting that wrong cost a run.
  // `RegistrationsController#destroy` calls `Waitlists::PromoteNext` inline
  // before it renders, so by the time the DELETE above returned, the
  // promotion had already happened. Only the email and the push are deferred.
  //
  // The first version of this polled `page.reload()` in a loop for 30
  // seconds. Promotion had in fact succeeded on the very first pass — but
  // each reload fires half a dozen API calls, and a few dozen reloads walked
  // straight into rack-attack's `req/ip` limit (300 per 5 minutes). The page
  // then rendered "Too many requests. Please wait a moment and try again."
  // for the rest of the run, so the assertion could never pass and the
  // failure message blamed the waitlist. A real person reloads once.
  //
  // Asserting the API first, then the UI: if promotion ever *does* become
  // asynchronous, the API assertion is the one that fails, and it fails
  // saying so rather than leaving a starved page to be interpreted.
  const waiterApi = await rally.apiAs(waiter);
  const waiterRegistrations = await waiterApi.get("/api/v1/registrations");
  const forThisEvent = (await waiterRegistrations.json()).registrations.filter(
    (r: { event_id: string; status: string }) =>
      r.event_id === event.id && r.status !== "cancelled",
  );
  expect(
    forThisEvent,
    "the waitlist entry was not promoted. Promotion is inline in " +
      "RegistrationsController#destroy, so this is not a timing problem — " +
      "check Waitlists::PromoteNext, whose failures are swallowed by design.",
  ).toHaveLength(1);

  // And the person sees it on their next visit. One reload, not a loop.
  await page.reload();

  // **They are asked to pay, not told they're registered** — and that is the
  // whole reason this scenario uses a paid event.
  //
  // `Waitlists::PromoteNext` creates the registration with
  // `payment_status: amount.zero? ? "paid" : "unpaid"`, so on a paid race a
  // promotion secures the place and leaves the money outstanding; its own
  // header says so. The event page branches on exactly that, rendering the
  // payment panel rather than the "You're registered" block. Asserting the
  // latter here was asserting the *free*-event outcome on an event this
  // scenario deliberately made cost $25.
  await expect(page.getByText("Scan with ABA Mobile")).toBeVisible();
  await expect(page.getByText("$25.00 — code expires in")).toBeVisible();

  // Now finish it. Nothing else in the suite covers this stretch: a promoted
  // registration joining the ordinary KHQR flow and coming out the far side
  // paid. The waitlist journey is the only place that pairing occurs.
  const promotedPayment = await rally.payLatest();
  // "rly" is a participant registration payment; "pln" would be an organizer
  // paying to publish. Two flows through one gateway — see
  // `.claude/rules/payments.md`.
  expect(promotedPayment.tran_id).toMatch(/^rly/);
  expect(promotedPayment.amount).toBe("25.00");

  // Same three-hop wait as journeys 2 and 3: webhook → job →
  // check-transaction, then the panel's own poll.
  //
  // `exact: true` for the same reason as the waitlist heading above —
  // `eventDetail.toastPaid` also contains this phrase.
  await expect(
    page.getByText("You're registered", { exact: true }),
  ).toBeVisible({ timeout: 30_000 });

  // A place was genuinely transferred, not double-counted: still exactly one
  // registration on the event, and it belongs to somebody new.
  const afterPromotion = await rally.api.get(`/api/v1/events/${event.id}`);
  expect((await afterPromotion.json()).event.registrations_count).toBe(1);

  // And the person told about it is the one who was waiting. The bell row is
  // always written regardless of notification preferences — that is a house
  // rule (`.claude/rules/notifications.md`), and the reason for it is that
  // someone who muted the emails still needs a way to find out.
  const notifications = await waiterApi.get("/api/v1/notifications");
  const kinds = (await notifications.json()).notifications.map(
    (n: { kind: string }) => n.kind,
  );
  expect(kinds).toContain("promoted_from_waitlist");

  // The removed participant's own list is deliberately *not* asserted here.
  // `#destroy` soft-deletes, and whether a discarded row still surfaces in
  // `GET /registrations` is a separate question with its own request spec;
  // pinning it here would couple this journey to a decision it has no stake
  // in. The count above already proves the place wasn't double-counted.
});
