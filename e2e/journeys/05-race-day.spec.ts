import { test, expect } from "../fixtures/rally";

/**
 * Journey 5 — race day. The organizer checks a runner in at the start line,
 * then imports finish times from the timing system afterwards, and the
 * results appear on the public event page.
 *
 * Crosses: check-in → `Results::ImportCsv` → bib matching → the leaderboard.
 *
 * The seam: **the CSV comes from a chip-timing system, which knows bibs and
 * has never heard of an entrant's email address.** Rally matches on bib
 * first and email second for exactly that reason
 * (`.claude/rules/certificates.md`), and this journey uploads the shape of
 * file an organizer actually has rather than the one the importer used to
 * demand.
 */

// Two finishers, bib-keyed, in the order a timing export would produce.
// `finish_time` accepts "H:MM:SS"; the faster runner is listed second on
// purpose, so the leaderboard has to sort rather than echo the file.
const TIMING_EXPORT = ["bib,finish_time", "A101,1:32:10", "A102,1:28:45"].join(
  "\n",
);

test("an organizer checks people in and imports the timing file", async ({
  rally,
  page,
}) => {
  const world = await rally.reset("finished_event");
  const event = world.events!.main!;
  const one = world.registrations!.finisher_one!;
  const two = world.registrations!.finisher_two!;

  await rally.signIn(world.users.organizer!);
  await page.goto(event.manage_url);

  // ── Check-in ───────────────────────────────────────────────────────────
  await page.getByRole("tab", { name: "Check-in" }).click();

  // The counter is the assertion, not the button state: it is computed from
  // the summary endpoint rather than from the rows on screen, which is the
  // arrangement that lets the list be paginated without the stat cards
  // lying. Nobody is checked in yet.
  await expect(page.getByText("0 / 2 checked in")).toBeVisible();

  // Check in whoever is listed first. Scoped to the row so the click can't
  // land on a different participant's button.
  await page.getByRole("button", { name: "Check in" }).first().click();

  await expect(page.getByText("1 / 2 checked in")).toBeVisible();

  // ── Import the timing file ─────────────────────────────────────────────
  await page.getByRole("tab", { name: "Results" }).click();
  await expect(page.getByText("Import results (CSV)")).toBeVisible();

  // Straight at the input. It is `className="hidden"` and opened by a button
  // that triggers the browser's native file dialog — which Playwright cannot
  // drive. `setInputFiles` works on hidden inputs precisely so tests don't
  // have to.
  await page.locator('input[type="file"]').setInputFiles({
    name: "timing-export.csv",
    mimeType: "text/csv",
    buffer: Buffer.from(TIMING_EXPORT, "utf8"),
  });

  // Both rows matched. The number matters: a summary reporting "1 result
  // updated" would mean one bib didn't match, which is the failure this
  // journey exists to catch and is invisible from the leaderboard alone
  // (one result still renders perfectly well).
  await expect(page.getByText("2 results updated.")).toBeVisible();

  // ── The public page shows the placings ─────────────────────────────────
  //
  // Signed out: results are for the people who ran and the people who
  // didn't, and the leaderboard renders for anyone.
  await rally.signOut();
  await page.goto(event.url);

  await expect(page.getByText("Results")).toBeVisible();
  await expect(page.getByText("1:28:45")).toBeVisible();
  await expect(page.getByText("1:32:10")).toBeVisible();

  // Ranked by time, not by file order — the faster runner was second in the
  // CSV. Asserted against the API rather than by reading the rendered
  // table's order, which is the sort of DOM-shape assertion that breaks the
  // day someone adds a column.
  //
  // The event has no event types, so the leaderboard is a single group
  // (`Results::BuildLeaderboard` returns one nil-typed group in that case).
  const leaderboard = await rally.api.get(`/api/v1/events/${event.id}/results`);
  const { groups } = await leaderboard.json();
  expect(groups).toHaveLength(1);

  const placings = groups[0].results as Array<{
    placement: number;
    registration_id: string;
    finish_time_seconds: number;
  }>;
  expect(placings).toHaveLength(2);

  // A102 ran 1:28:45 and was listed *second* in the file. First place is
  // decided by the clock.
  expect(placings[0].placement).toBe(1);
  expect(placings[0].registration_id).toBe(two.id);
  expect(placings[0].finish_time_seconds).toBe(1 * 3600 + 28 * 60 + 45);

  expect(placings[1].placement).toBe(2);
  expect(placings[1].registration_id).toBe(one.id);
  expect(placings[1].finish_time_seconds).toBe(1 * 3600 + 32 * 60 + 10);
});
