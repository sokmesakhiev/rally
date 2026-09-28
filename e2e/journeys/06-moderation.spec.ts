import { test, expect } from "../fixtures/rally";

/**
 * Journey 6 — someone reports an event, a reviewer finds it in the queue,
 * takes it down, and sign-ups stop.
 *
 * Crosses: anonymous reporting → the admin queue → suspension → the
 * registration guard.
 *
 * Two properties this journey exists to hold, both of which are decisions
 * rather than accidents (`.claude/rules/events-and-moderation.md`):
 *
 *   - **Reporting is intake, not enforcement.** Nothing in the report path
 *     changes an event's state. A platform that strangers can make take an
 *     organizer's paid work down is worse than one that takes an hour to
 *     read a complaint — so the event must still be live and still be
 *     registerable after the report.
 *   - **Suspension is refused at the model, not hidden in the UI.** Until
 *     recently neither `Registration` nor `WaitlistEntry` looked at
 *     `suspended_at`, so anyone holding the event id could register for an
 *     event an admin had taken down, and pay for it. The last act of this
 *     journey is going back to the page and finding the door shut.
 */

test("a reported event reaches the queue, gets suspended, and stops taking sign-ups", async ({
  rally,
  page,
}) => {
  const world = await rally.reset("admin");
  const event = world.events!.main!;

  // ── Anyone can report, including someone with no account ───────────────
  //
  // The route carries no `authenticate_user!` on purpose: someone frightened
  // by a gathering is the least likely person to want to make an account
  // first. So this half runs signed out.
  await page.goto(event.url);
  await page.getByRole("button", { name: "Report this event" }).click();

  await expect(
    page.getByText("Tell our team why this event concerns you"),
  ).toBeVisible();
  await page.getByRole("button", { name: "Gambling" }).click();
  await page
    .locator("#report-details")
    .fill("The listing is a card game with buy-ins, not a run.");
  await page.getByRole("button", { name: "Send report" }).click();

  await expect(
    page.getByText("Thanks — our team will review this event"),
  ).toBeVisible();

  // Still live, still registerable. The endpoint deliberately returns the
  // same response for a first report, a duplicate, and an already-suspended
  // event — it is not an oracle — so this is checked against the event
  // itself rather than against what the dialog said.
  const afterReport = await rally.api.get(`/api/v1/events/${event.id}`);
  expect((await afterReport.json()).event.is_published).toBe(true);

  // ── A reviewer finds it ────────────────────────────────────────────────
  await rally.signIn(world.users.admin!);
  await page.goto("/admin?tab=reports");

  await expect(page.getByText(event.title)).toBeVisible();
  // The queue is grouped by event, because a reviewer's unit of work is
  // "should this event stay up" — twelve reports on one event are one
  // decision, not twelve.
  await expect(page.getByText("1 event waiting on us")).toBeVisible();

  // ── …and takes it down ─────────────────────────────────────────────────
  //
  // From the Events tab, not from the queue. Resolving a report closes a
  // ticket; suspending is its own act with its own audit entry, so that the
  // record shows a reviewer chose it rather than it being implied by
  // clearing a queue. The queue's own copy says as much.
  await page.getByRole("tab", { name: "Events" }).click();
  await page
    .getByPlaceholder("Search by title, description or place")
    .fill(event.title);

  await page
    .getByRole("button", { name: "Suspend", exact: true })
    .first()
    .click();
  await expect(page.getByText(`Suspend "${event.title}"?`)).toBeVisible();

  // The reason is required and is shown to the organizer — the confirm
  // button stays disabled until there is one.
  await page
    .getByLabel("Reason (required — shown to the organizer)")
    .fill("Gambling — reported and confirmed by review.");
  await page.getByRole("button", { name: "Suspend event" }).click();

  // The row's action flips to "Unsuspend" — durable state, unlike the
  // "Event suspended — the organizer has been emailed" toast, which is gone
  // in a few seconds. Asserting the toast passes or fails on how quickly the
  // request came back. Journeys 1 and 2 learned this the expensive way.
  await expect(
    page.getByRole("button", { name: "Unsuspend", exact: true }).first(),
  ).toBeVisible();

  // ── The door is shut ───────────────────────────────────────────────────
  await rally.signOut();
  await page.goto(event.url);

  await expect(
    page.getByText("This event is no longer available"),
  ).toBeVisible();
  // No Register button to click, and — more importantly — no way to reach
  // one. The guard that matters is the model validation behind this, which
  // the API check below reaches directly.
  await expect(page.getByRole("button", { name: "Register" })).toHaveCount(0);

  // Straight at the endpoint, bypassing the UI entirely, because "anyone
  // with the event id could still register" was the actual bug. A UI that
  // hides the button proves nothing about it.
  const participantApi = await rally.apiAs(world.users.participant!);
  const refused = await participantApi.post(
    `/api/v1/events/${event.id}/registrations`,
    { data: {} },
  );
  expect(refused.ok()).toBe(false);
  // Its own error code, not folded into `registration_closed` — telling a
  // participant the organizer closed sign-ups would send them to ask the
  // organizer to reopen something the organizer cannot reopen.
  expect((await refused.json()).code).toBe("event_suspended");
});
