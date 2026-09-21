# Rally end-to-end testing — design

**Status:** accepted · **Date:** 2026-09-21 · **Scope:** v1
**Progress:** Phase 0 built (see `e2e/README.md`); Phases 1–3 outstanding.

Rally has 1,728 RSpec examples covering the API at 94% line / 81% branch, and
a frontend suite covering the components that carry logic. Neither answers the
question a business owner actually asks: **can an organizer publish an event,
take money for it, and hand a finisher a certificate?** Every one of those
steps is individually tested and nothing tests the seam between them.

That seam is where this month's bugs lived. The sitemap emitted relative URLs;
the events endpoint refused `per_page=1000` and the caller swallowed the 422;
a notification pointed at a URL the bell's allowlist didn't know. Each
component was green. The integration was broken.

This document describes a small suite of end-to-end tests that exercise whole
business processes against a real browser, a real Rails server and a real
database.

---

## 1. Decisions

### D1 — Playwright, running against a local full stack

Rails on `:3000`, Vite on `:8080`, and a dedicated `rally_e2e` Postgres
database, all started by the test runner.

Playwright over Cypress for two reasons that matter here specifically: the
payment flow leaves the app's own origin, which Cypress handles awkwardly, and
Playwright's trace viewer replays a failed run with DOM snapshots at every
step. E2E failures are frequently un-reproducible on a second run; a trace is
the difference between diagnosing one and shrugging at it.

Over Rails system specs, which would have been cheaper to bolt onto the
existing RSpec suite: **the frontend is a separate SPA deployed to S3 and
served by CloudFront.** Rails never serves it in production. A Capybara suite
would have to serve a build Rails otherwise has no relationship with, so the
thing under test would stop resembling the thing that ships — and the
CloudFront rewrite rule that turned `/sitemap.xml` into an HTML 200 is exactly
the class of bug that setup would hide.

*Rejected:* frontend-only with a mocked API. Fast, stable, and it would not
have caught a single one of the integration bugs listed above, because every
one of them lived in a disagreement between two sides that a mock would have
papered over.

### D2 — A fake PayWay gateway, not ABA's sandbox

`ABA_PAYWAY_BASE_URL` is already per-environment in `config/payway.yml`
specifically so an environment can't silently fall back to the wrong gateway.
The e2e environment points it at a small local HTTP stub.

The stub does two things:

1. Answers `generate_qr` with a well-formed QR payload and a transaction id.
2. **Fires the real webhook back at Rally**, so `EventPlanPayment#mark_paid!`
   and the registration payment path execute for real.

That second half is the point. A stub that only returns a QR code would test
the request and skip the part where money is confirmed and an event goes live.
The webhook round trip means the test covers our signature checking, our
idempotency, and the state transition — everything except ABA's own servers.

*Rejected:* ABA's sandbox. It tests their contract, which is worth something,
but it needs credentials, network and their uptime, and a sandbox that changes
behaviour breaks the suite for a reason nobody on this side can fix. **A
contract test against the sandbox is a separate, later idea** — one test, run
rarely, asserting their response shape still matches what the stub imitates.

### D3 — Run on demand and nightly, never on a pull request

```yaml
on:
  workflow_dispatch:      # any branch, any time
  schedule:
    - cron: "0 18 * * *"  # nightly
# deliberately NOT on: pull_request
```

The brief was "ideally not in CI", and the reason is sound: E2E suites are slow
and occasionally flaky, and a flaky test blocking an unrelated PR teaches
people to bypass the pipeline.

But "not in CI" usually decays into "nobody knows when it broke". This
codebase has the canonical example — `GenerateCertificatesJob` documented a
schedule it wasn't on, had never run in production, and its spec passed
throughout. A nightly run costs nothing on the critical path and bounds the
damage to one day. Failures go to the same Telegram channel as deploys.

### D4 — The database is reset over HTTP, by a route that cannot exist in production

Playwright is a separate process from Rails; it cannot call
`DatabaseCleaner.clean`. So the e2e environment mounts one route:

```
POST /api/e2e/reset    { scenario: "organizer_with_published_event" }
```

It truncates and re-seeds to a named scenario, returning the ids and
credentials the test needs.

Three guards, because a "reset the database" endpoint is the most dangerous
thing in this document:

- The route is **inside `if Rails.env.e2e?`** in `routes.rb`, so in any other
  environment it is not merely forbidden, it is not routable.
- The controller re-asserts the environment and aborts otherwise — belt and
  braces, so a future refactor that moves the route out of the guard doesn't
  silently arm it.
- **A request spec asserts the route is absent in the test environment.** The
  guard is a prose rule until a test enforces it; this is the house pattern
  (see the PayWay serializer guard in `spec/requests/impersonation_spec.rb`).

*Rejected:* seeding through the public API. It would be slower, would need an
admin account bootstrapped some other way, and would make every test depend on
the correctness of the endpoints it is trying to test — a failing registration
endpoint would break the *setup* of tests for unrelated journeys.

### D5 — A new `e2e` Rails environment, not `test` or `development`

`config/environments/e2e.rb`, inheriting production-like settings but pointed
at `rally_e2e` and the fake gateway.

Not `test`: RSpec owns that environment and its database, and a Playwright run
would truncate tables out from under a developer running specs.

Not `development`: the e2e run would destroy the developer's own data, which
is the fastest way to make people stop running it.

### D6 — Seeded scenarios, not a fresh registration for every test

Each test declares the world it needs (`POST /api/e2e/reset` with a scenario
name) rather than clicking through setup. A test for the certificate flow
should not spend forty seconds registering three participants through the UI
before it can begin — that makes it slow *and* makes it fail for reasons that
have nothing to do with certificates.

The **one exception is the journey under test**. A test of registration
registers through the UI; a test of check-in seeds the registrations.

---

## 2. The journeys in scope for v1

Six, chosen because each is a process a customer pays for, and each crosses at
least one seam the unit tests can't see.

| # | Journey | Crosses |
|---|---|---|
| 1 | **Organizer publishes a free event** — sign in, create, add race types, pick the free plan, publish, see it in the public catalogue | Event creation → plan gate → `publicly_visible` scope |
| 2 | **Organizer publishes a paid event** — pick a paid plan, get a KHQR code, the fake gateway confirms, the event goes live | Plan payment → gateway → webhook → `mark_paid!` → publish |
| 3 | **Participant registers and pays** — browse, register for a paid race, pay by KHQR, receive confirmation | Registration → capacity → payment → notification |
| 4 | **Full event offers a waitlist, and promotes** — register into a full race, join the waitlist, cancel a registration, the next entry is promoted | Capacity → waitlist → `PromoteNext` → notification |
| 5 | **Race day** — check in a participant by QR, import a results CSV, see the leaderboard | Check-in role → results import → bib matching → leaderboard |
| 6 | **Moderation** — report an event anonymously, see it in the admin queue, suspend it, confirm sign-ups are refused | Reporting → queue → suspension → the registration guard |

Deliberately **out of scope for v1**: certificates (they shell out to
LibreOffice and take seconds per render — worth testing, but as its own slow
job rather than in the main suite), impersonation, support chat, and anything
requiring a second browser context.

---

## 3. Layout

```
e2e/
  playwright.config.ts        # projects, webServer, trace on first retry
  fixtures/
    rally.ts                  # test fixture: resets to a scenario, returns ids
    api.ts                    # direct API calls for setup and assertions
  journeys/
    01-publish-free-event.spec.ts
    02-publish-paid-event.spec.ts
    03-register-and-pay.spec.ts
    04-waitlist-promotion.spec.ts
    05-race-day.spec.ts
    06-moderation.spec.ts
  support/
    fake-payway/              # the stub gateway (node, ~100 lines)
  README.md                   # how to run it, what to do when it fails
backend/
  config/environments/e2e.rb
  app/controllers/api/e2e/    # reset + scenarios, e2e env only
  db/e2e_scenarios.rb         # the named worlds
```

`e2e/` sits at the repo root rather than inside `frontend/`, because it tests
both halves and belongs to neither. It gets its own `package.json` so
Playwright never enters the frontend's dependency tree or its `npm ci`.

---

## 4. Rollout

| Phase | Ships |
|-------|-------|
| **0 — foundation** ✅ | `e2e` environment, reset endpoint + its absence-guard spec, fake gateway, Playwright config, one smoke test that signs in. Nothing else is possible until this works. |
| **1 — the money paths** | Journeys 1, 2, 3. The highest-value half of the suite. |
| **2 — the rest** | Journeys 4, 5, 6. |
| **3 — automation** | The `workflow_dispatch` + nightly workflow, Telegram reporting, trace artefacts on failure. |

Phase 0 is the risky one and the only one worth estimating carefully: if
standing up the environment turns out to be painful, that is worth knowing
before six journeys are written against it.

---

## 5. What will make this fail, and what we do about it

Honest list, because E2E suites usually die of these rather than of bad tests:

- **Flakiness from timing.** Mitigated by Playwright's auto-waiting and by
  never asserting on a fixed sleep. Any test that needs a `waitForTimeout` is
  a bug report about the app, not a test to patch.
- **Slowness.** Six journeys should stay under five minutes. If it grows past
  that, split the nightly job rather than dropping coverage.
- **Drift between the fake gateway and the real one.** Bounded by keeping the
  stub tiny and by the later contract test in D2. Written down here because
  the stub is the one place this suite can lie to us.
- **Nobody runs it.** The nightly schedule is the answer, and the reason D3
  didn't simply accept "local only".

---

## 6. Open questions

1. **Does the nightly run need a real browser matrix?** One Chromium project
   to start. Firefox and WebKit multiply the runtime for a class of bug this
   app is unlikely to hit — but the Khmer font rendering is a genuine
   unknown.
2. **Should journey 3 assert the confirmation email?** The e2e environment
   could expose the mail queue. Useful, slightly invasive; deferred.
3. **Where do traces go on a nightly failure?** GitHub artefacts are simplest;
   they expire. Fine unless a failure goes unlooked-at for weeks, which is its
   own problem.
