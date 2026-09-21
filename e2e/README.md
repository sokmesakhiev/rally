# Rally end-to-end tests

Six business journeys against a real browser, a real Rails server and a real
database. Why this exists and what it deliberately doesn't cover:
[`docs/e2e-testing-design.md`](../docs/e2e-testing-design.md).

**Status: Phase 0.** The harness works and one smoke test proves it. The six
journeys land in Phases 1 and 2.

## Running it

```bash
cd e2e
npm install
npm run install:browsers    # chromium, once per machine
npm test
```

That's the whole instruction. `npm test` starts three servers, waits for all
of them, and stops them when it finishes:

| Port | What | Started from |
|------|------|--------------|
| 3002 | the fake PayWay gateway | `support/fake-payway/server.mjs` |
| 3000 | Rails, `RAILS_ENV=e2e`, against `rally_e2e` | `../backend` |
| 8080 | Vite, serving the SPA against `:3000` | `../frontend` |

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

## It is not in CI on pull requests, on purpose

`workflow_dispatch` plus a nightly cron (Phase 3). E2E suites are slow and
occasionally flaky, and a flaky test blocking an unrelated PR teaches people
to bypass the pipeline. The nightly run is what stops "not in CI" decaying
into "nobody knows when it broke" — this repository has the canonical example
of that in `GenerateCertificatesJob`, which documented a schedule it wasn't on
and had never run in production.

## Writing a journey

```ts
import { test, expect } from "../fixtures/rally";

test("an organizer publishes a free event", async ({ rally, page }) => {
  const world = await rally.reset("organizer");
  await rally.signIn(world.users.organizer!);
  // ...
});
```

Three rules, each of which has a reason rather than a preference behind it:

- **Seed the world, click the journey.** `rally.reset(scenario)` sets up
  everything the test isn't about. A check-in test that first registers three
  participants through the UI is slow *and* fails for reasons that have
  nothing to do with check-in. Scenarios live in
  [`backend/db/e2e_scenarios.rb`](../backend/db/e2e_scenarios.rb).
- **Never `waitForTimeout`.** Playwright's assertions retry on their own; wait
  for the thing you actually mean (`await expect(x).toBeVisible()`). A journey
  that genuinely needs a sleep is a bug report about the app.
- **Assert on what a person would see.** Roles and visible text, not CSS
  classes. A test that breaks when a class is renamed tells you nothing.

### Payments

`rally.pay(tranId)` is the stand-in for a human paying a KHQR code. It marks
the transaction approved at the gateway, and the gateway then fires Rally's
real webhook at the callback URL Rally itself supplied.

That matters for how you assert: **the webhook only triggers a job.** Rally
calls the gateway back to ask what happened, and that happens asynchronously
(`:async` job adapter in this environment). So after `rally.pay(...)`, wait
for the *consequence* — the event showing as published, the registration
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
5. **Ports already in use.** Outside CI the suite reuses a server that's
   already listening, so a `bin/rails server` you left running on 3000 will be
   used as-is — in the *wrong environment*, against your development database.
   If a run starts doing inexplicable things to your own data, that's this.
6. **A journey trips a rate limit (429).** rack-attack is enabled here and its
   counters are cleared on every `reset`, so this means one journey is making
   more requests than a real person would — or a limit is genuinely too tight.
   Widening the reset isn't the fix; find out which.

## What the suite can't tell you

Written down because a test suite's blind spots are worth knowing before you
trust a green run:

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
