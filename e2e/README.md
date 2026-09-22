# Rally end-to-end tests

Six business journeys against a real browser, a real Rails server and a real
database. Why this exists and what it deliberately doesn't cover:
[`docs/e2e-testing-design.md`](../docs/e2e-testing-design.md).

**Status: 9 of 10 green.** All six journeys plus the harness smoke test are
written and the nightly workflow is wired. Three runs in, **every failure has
been the test's own assertion, never the application** — the publish, payment,
waitlist, promotion and moderation chains have all been observed working, in
several cases by reading the page snapshot from the run that "failed".

Journey 4 is the one still to be seen green. The rules under "Writing a
journey" are where those lessons live; they're worth reading before adding a
journey.

## Running it

```bash
cd e2e
npm install
npm run install:browsers    # chromium, once per machine
npm test
```

That's the whole instruction. `npm test` starts three servers, waits for all
of them, and stops them when it finishes:

| Port | What                                        | Started from                     |
| ---- | ------------------------------------------- | -------------------------------- |
| 3002 | the fake PayWay gateway                     | `support/fake-payway/server.mjs` |
| 3000 | Rails, `RAILS_ENV=e2e`, against `rally_e2e` | `../backend`                     |
| 8080 | Vite, serving the SPA against `:3000`       | `../frontend`                    |

The `rally_e2e` database is created and migrated on the way up (`db:prepare`),
so there is no setup step to forget.

Useful variants:

```bash
npm run test:headed                  # watch it happen
npm run test:ui                      # pick and re-run individual tests
npm test -- journeys/00-smoke.spec.ts
npm run report                       # open the last HTML report
E2E_RAILS_LOG_LEVEL=debug npm test   # when the API is the suspect
```

## What's in here

| File                            | Journey                        | The seam it crosses                                          |
| ------------------------------- | ------------------------------ | ------------------------------------------------------------ |
| `00-smoke.spec.ts`              | the harness itself             | three servers, a resettable database, a seeded sign-in       |
| `01-publish-free-event.spec.ts` | organizer publishes free       | event creation → plan gate → `Event.publicly_visible`        |
| `02-publish-paid-event.spec.ts` | organizer publishes paid       | plan payment → gateway → webhook → `mark_paid!` → publish    |
| `03-register-and-pay.spec.ts`   | participant registers and pays | catalogue → registration → capacity → payment                |
| `04-waitlist-promotion.spec.ts` | a place frees up               | capacity → waitlist → `PromoteNext` → notification → payment |
| `05-race-day.spec.ts`           | check-in and results           | check-in → `ImportCsv` → bib matching → leaderboard          |
| `06-moderation.spec.ts`         | report and suspend             | reporting → admin queue → suspension → registration guard    |

Journey 1 is the only one that builds its event through the UI. Every other
journey seeds one — the form is journey 1's subject and nobody else's.

## It is not in CI on pull requests, on purpose

`.github/workflows/e2e.yml` — `workflow_dispatch` plus a nightly cron at 18:00
UTC (01:00 in Phnom Penh, so a failure is waiting in the morning). E2E suites
are slow and occasionally flaky, and a flaky test blocking an unrelated PR
teaches people to bypass the pipeline. The nightly run is what stops "not in
CI" decaying into "nobody knows when it broke" — this repository has the
canonical example of that in `GenerateCertificatesJob`, which documented a
schedule it wasn't on and had never run in production.

Traces are uploaded as artefacts on every run and kept for seven days. Only
_failures_ go to Telegram: a green message every night is a message people
learn to scroll past, and the next one they scroll past is the red one.

A manual dispatch takes an optional path filter, so you can re-run one journey
against a branch without waiting for the other five.

## Writing a journey

```ts
import { test, expect } from "../fixtures/rally";

test("an organizer publishes a free event", async ({ rally, page }) => {
  const world = await rally.reset("organizer");
  await rally.signIn(world.users.organizer!);
  // ...
});
```

Six rules. The first three are principles; the last three were each paid for
with a failed run, and the failure was the test's fault every time:

- **Seed the world, click the journey.** `rally.reset(scenario)` sets up
  everything the test isn't about. A check-in test that first registers three
  participants through the UI is slow _and_ fails for reasons that have
  nothing to do with check-in. Scenarios live in
  [`backend/db/e2e_scenarios.rb`](../backend/db/e2e_scenarios.rb).
- **Never `waitForTimeout`.** Playwright's assertions retry on their own; wait
  for the thing you actually mean (`await expect(x).toBeVisible()`). A journey
  that genuinely needs a sleep is a bug report about the app.
- **Assert on what a person would see.** Roles and visible text, not CSS
  classes. A test that breaks when a class is renamed tells you nothing.
- **Assert durable state, never a confirmation.** This one cost a whole run
  on the first attempt. "Event published!" and "Payment received — event
  published!" are rendered by `PlanPaymentPanel`, and the same effect that
  shows them invalidates the event query — which unmounts the entire publish
  section, message included. The text exists only inside a race it usually
  loses. Toasts are the same story with a timer. Reach for the thing still on
  screen a minute later: the "Unpublish" button, the current-plan line, the
  row action that flipped.
- **Never poll by reloading the page.** A reload fires half a dozen API
  calls, so `expect.poll(async () => { await page.reload(); ... })` is a
  request amplifier: a few dozen iterations trip rack-attack's `req/ip` limit
  (300 per 5 minutes), the page starts rendering "Too many requests", and
  from then on the assertion can never pass — while the failure message
  blames whatever you were waiting for. That is exactly how journey 4 spent
  a run accusing the waitlist of a bug it didn't have. Check whether you need
  to wait at all first: much of Rally is synchronous inside the request that
  triggered it. When you genuinely must wait, poll a single API endpoint, or
  let `expect(locator)` retry against the page you already loaded.
- **Check what the scenario actually set up before asserting an outcome.**
  Journey 4 seeds a _paid_ race on purpose, so its promoted registration
  comes back `unpaid` and the page shows the payment panel — asserting
  "You're registered" there was asserting the free-event outcome against an
  event the same file had deliberately priced at $25. When an assertion
  fails, read `error-context.md` in `test-results/`: it carries the full
  accessibility snapshot of the page, which says what the app did rather
  than what you assumed it would do. Every failure in this suite so far has
  been diagnosed from that file alone.
- **Prefer `{ exact: true }` for short phrases.** Rally's toasts tend to open
  with the same words as the heading they confirm — "You're on the waitlist",
  "You're registered" — so a substring match resolves to two elements and
  fails on strict mode. Whether it fails depends on whether the toast is
  still up, which makes it a coin-flip rather than a test.

### Payments

`rally.pay(tranId)` is the stand-in for a human paying a KHQR code. It marks
the transaction approved at the gateway, and the gateway then fires Rally's
real webhook at the callback URL Rally itself supplied.

That matters for how you assert: **the webhook only triggers a job.** Rally
calls the gateway back to ask what happened, and that happens asynchronously
(`:async` job adapter in this environment). So after `rally.pay(...)`, wait
for the _consequence_ — the event showing as published, the registration
showing as paid — never for a fixed delay.

## When it fails

Work down this list; it's ordered by how often each turns out to be the answer.

1. **Read the trace.** `npm run report`, open the failed test, step through
   the DOM snapshots. This answers most failures outright and is the reason
   the suite is Playwright rather than Capybara.
2. **Check which server broke.** Rails and Vite output is piped into the
   Playwright run. An API 500 shows up there with a real backtrace —
   `consider_all_requests_local` is on in this environment specifically so it
   does.
3. **`Request origin not allowed` / CORS failures.** `FRONTEND_URL` and
   `BACKEND_URL` are set in `playwright.config.ts`; they have to match the
   ports actually in use.
4. **`fake-payway has no route for …` in the log.** Rally is calling a gateway
   endpoint the stub doesn't imitate. That's the drift the design doc warns
   about — fix the stub to match what the real gateway does, not to whatever
   makes the test pass.
5. **`key not found: "..."` (KeyError) during Rails boot.** Something reads a
   required environment variable at load time, and `config.eager_load = true`
   means load time is boot time here. Development and test get away with it
   because `dotenv-rails` loads `backend/.env` for them; this environment has
   no dotenv, on purpose — a suite that inherited your personal `.env` could
   pick up your real `ABA_PAYWAY_BASE_URL` and start talking to a real
   gateway.

   The fix is to name the value in `config/environments/e2e.rb`, alongside
   `SECRET_KEY_BASE` and `JWT_SECRET`, not to add dotenv to the `e2e` group.

6. **Ports already in use.** Outside CI the suite reuses a server that's
   already listening, so a `bin/rails server` you left running on 3000 will be
   used as-is — in the _wrong environment_, against your development database.
   If a run starts doing inexplicable things to your own data, that's this.
7. **A journey trips a rate limit (429).** rack-attack is enabled here and its
   counters are cleared on every `reset`, so this means one journey is making
   more requests than a real person would — or a limit is genuinely too tight.
   Widening the reset isn't the fix; find out which.

   It has been the former every time so far, and it does not announce itself
   as a 429: the page renders "Too many requests. Please wait a moment and
   try again." where the content should be, and whatever you were asserting
   on simply never appears. If a panel is mysteriously empty, look for that
   string in the page snapshot before suspecting the feature.

## Known gaps found while writing this

Things the journeys had to work around. Each is a small real problem in the
app, recorded here rather than papered over with a clever selector:

- **The organizer's "remove participant" control has no accessible name.**
  It is an icon-only ghost button (`Trash2`), so the only way to click it is
  a selector tied to an SVG. Journey 4 frees its place over the API instead
  and says so inline. A screen-reader user has the same problem, which makes
  this an accessibility bug before it is a testing one — one `aria-label`
  fixes both.
- **The results import still says "Matches by email."** The backend has
  matched on bib first and email second since bib numbers landed
  (`.claude/rules/certificates.md`), and the export CSV leads with `Bib`.
  Journey 5 uploads a bib-keyed file, which is what a timing system actually
  produces, so the suite exercises the real path while the copy describes the
  old one. `results.importDesc` in `en.json` and `km.json`.
- **No `data-testid` anywhere in the app.** Every selector here is a role,
  a label or visible English text. That has an upside — a journey breaks if a
  translation key goes missing — and a cost: these journeys are more
  sensitive to copy changes than they would otherwise be. If a particular
  assertion starts churning, a testid on that one control is the cheap fix,
  not a rewrite.

## What the suite can't tell you

Written down because a test suite's blind spots are worth knowing before you
trust a green run:

- **Journey 4 has not been seen green.** Its assertion was corrected from the
  saved page snapshot, which showed the promotion had in fact happened (the
  notification bell read "1 unread") while the page was being rate-limited by
  the test's own reload loop. The correction is reasoned, not observed. The
  other nine have passed.

- **The gateway is a stub.** It imitates ABA PayWay's response shapes, taken
  from what the client and the webhook job actually read. If ABA changes those
  shapes, this suite stays green and production breaks. The planned answer is
  one rarely-run contract test against ABA's real sandbox (design doc, D2).
- **Jobs run in-process without retries.** Production uses Solid Queue in its
  own ECS service. Nothing here exercises retry, backoff, or a worker being
  down.
- **One browser.** Chromium only. Khmer font rendering across engines is a
  genuine unknown and wants its own screenshot test rather than running
  everything three times.
- **Nothing here touches production config.** `RAILS_ENV=e2e` is a value no
  Dockerfile, task definition or workflow sets, and `POST /api/e2e/reset` is
  not routable outside it — there's a spec that fails if that stops being
  true.
