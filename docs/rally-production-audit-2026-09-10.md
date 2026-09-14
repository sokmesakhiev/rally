# Rally — production readiness audit

*2026-09-10. Supersedes the operational conclusions in `rally-production-readiness-audit.md` (2026-07-30), which is now materially stale in both directions — several things it listed as missing have shipped, and at least one it recorded as fixed was later reverted in `terraform.tfvars`.*

## Verdict

**Rally is running in production and the core is genuinely sound.** The architecture is careful, the backend is well tested (87 spec files, ~1,400 examples), the database is configured the way you'd want it, and the payment integration is more rigorous than most — it never trusts a webhook payload, confirming every transaction with its own authenticated call.

It is **ready for real users at current scale, supervised.** It is **not yet ready to be left unattended**, for three reasons, none of which are architectural:

1. A participant can pay and silently lose their registration, with nothing flagging it.
2. Deleting an account doesn't remove what that person typed into support chat.
3. Nothing anywhere tells you production is broken.

None of these require redesign. They're roughly a week of focused work.

---

## Ranked by what would actually hurt

### 1. A paid registration can be cancelled, silently — money risk

`Registrations::ReleaseAbandoned` frees capacity held by registrations abandoned before payment. It decides by reading **our own** `payments.status`; it never re-checks with ABA before discarding.

The failure path:

1. Participant scans the KHQR code and pays. Money leaves their account.
2. ABA's webhook doesn't arrive — their outage, a network blip, our endpoint briefly down.
3. Participant closes the tab straight away, so the frontend never polls `GET /payments/:id`.
4. Our `payments.status` stays `pending`.
5. An hour later the sweep runs and discards the registration.

They paid, they have no spot, and **nothing surfaces the discrepancy**. Reconciliation would only happen if they complained.

Two things make this less bad than it sounds: there are two independent confirmation paths (webhook *and* polling), so both must fail; and `discard!` is a soft delete, so the row and its payment history survive and can be restored by hand. But the sweep is what converts a *transient* confirmation miss into a *permanent* customer-visible loss.

**Fix, cheapest first:** before `registration.discard!`, call ABA's Check Transaction for any `pending` payment on that registration and skip the discard if it comes back APPROVED. That's a handful of lines inside the existing row lock, and it closes the hole at the exact moment it would otherwise open. A nightly reconciliation job listing pending payments older than 24 hours would be a good second layer.

### 2. Account deletion leaves support-chat content behind — privacy risk

`User#discard!` is thorough about structured data: it replaces the email, scrambles the password, clears `google_uid`, nulls `display_name`/`avatar_url`/`phone`, and wipes PayWay credentials on owned organizations.

It does not touch `messages.body`.

Support chat is precisely where people paste things they wouldn't put in a profile field — phone numbers, addresses, card complaints, screenshots of problems. After "delete my account", all of that remains verbatim, attached to an anonymised user, readable by any admin in the console.

**Fix:** extend `discard!` to scrub or delete the participant's own messages inside the same transaction. Worth deciding deliberately whether staff replies in those threads survive (they're operational records) — but the participant's own text should go.

### 3. Support chat has no retention policy, and the privacy policy doesn't mention it

Chat messages are kept forever — Ticket H in `support-chat-tickets.md` is unbuilt, and `config/recurring.yml` has no sweep. Meanwhile `frontend/src/routes/privacy.tsx` has a Retention section that predates chat and doesn't mention support conversations at all.

Chat shipped days ago and introduced a **new category of personal data** with no stated policy governing it. That's the kind of gap that's trivial to close now and awkward to close after a year of accumulated threads.

**Fix:** pick a window (12 months is a defensible default), add the sweep to `recurring.yml` alongside the existing hourly jobs, and add a sentence to the privacy policy. The open question in the ticket — *what* window — is yours to answer, not mine.

### 4. Nobody would find out if production broke

There are **no CloudWatch alarms and no SNS topics** anywhere in `infrastructure/`. Sentry is properly configured and will catch exceptions, but Sentry can't tell you:

- the ECS task died and the ALB has no healthy targets
- RDS is out of connections, storage, or CPU credits (you're on `db.t3.micro` — CPU credits are a real cliff)
- Solid Queue has stalled and nothing is sending email or processing webhooks
- the ABA webhook endpoint has been returning 5xx for an hour

You would learn all of these from a user telling you. For a payments product that's the gap I'd close first after #1.

**Fix:** an SNS topic and four or five alarms — ALB healthy-host count, RDS free storage and CPU credit balance, ECS running-task count, and a log-metric filter on ERROR volume. A couple of hours of Terraform.

### 5. Single ECS task — and the fix depends on an unverified assumption

`terraform.tfvars` sets `ecs_desired_count = 1`. The July audit recorded raising this to 2; the tfvars value overrides that default, so it never took effect.

Deploys themselves are safe — `deployment_minimum_healthy_percent = 100`, `maximum_percent = 200`, plus a deployment circuit breaker, so ECS starts the replacement before stopping the old task. But a crash or AZ failure is a **full outage** until ECS schedules a new task. RDS is Multi-AZ (`db_multi_az` defaults to `true` and isn't overridden), so the database layer is fine; it's only the app tier that's a single point of failure.

The complication: scaling to 2 makes support chat's cross-task message fan-out load-bearing, and **that has never been verified** — the smoke test proved Solid Cable's write→poll→dispatch loop works, but couldn't observe delivery *between* tasks because there's only one. Run `scripts/cable-smoke.mjs` at `desired_count = 2` before or alongside that change, looking for `fan-out OK`.

### 6. Frontend quality gates are largely absent

| | Backend | Frontend |
|---|---|---|
| Test files | 87 | 5 |
| Examples | ~1,414 | 43 |
| Surface | 27 models, 41 controllers | 18 routes, 32 components |
| In CI | RSpec, RuboCop, Brakeman, bundler-audit | Vitest only |

CI runs **no typecheck and no lint** on the frontend. Vite's build strips types without checking them, so type errors ship silently — there is one live right now in `notification-bell.tsx` (a `TFunction` mismatch), which `npx tsc --noEmit` catches and nothing else does.

The untested surface includes the parts where mistakes are expensive: the payment panel, the registration flow, event creation. The backend equivalents are well covered, so the *rules* are enforced — but a frontend bug that sends the wrong amount or hides a capacity error would not be caught.

**Fix:** add `tsc --noEmit` to CI first — it's one job, it catches a real class of bug, and it's already passing bar one known error. ESLint needs its pre-existing backlog triaged before it can gate anything.

### 7. Sentry backend errors all group under one release

`config.release` reads `GIT_SHA`, which nothing sets — the ECS task definition always points at `:latest` and Terraform ignores `container_definitions`, so CI has no revision to inject the SHA into. Every backend error therefore groups under a single release, and "did this start with the last deploy?" is unanswerable. The frontend does this correctly (`VITE_GIT_SHA` at build time).

---

## Verified sound — don't spend time here

- **Database configuration is genuinely good.** Encrypted at rest, Multi-AZ, 7-day automated backups, deletion protection on, final snapshot on destroy, Performance Insights enabled, auto minor version upgrades. Better than most production apps this size.
- **Deploys are zero-downtime** even at one task, via min-healthy 100% / max 200% and a circuit breaker.
- **The payment integration is careful.** ABA's unsigned webhook is treated purely as a trigger; the real status change always comes from an authenticated Check Transaction. Approval is row-locked so the poller and webhook can't double-fire. This is the right design.
- **Brakeman's one suppressed warning is a false alarm** — RSA PKCS1 padding, which ABA's protocol mandates. The HMAC alongside it is SHA-512. No action needed.
- **Rate limiting is comprehensive** — per-IP and per-user throttles across sign-in, signup, password reset, verification, invitations, registrations, uploads, payments, cable tickets, and support messages, with the webhook and health check safelisted.
- **Auth is enforced on every request, not just sign-in.** Suspension and deletion are re-checked per request because JWTs are stateless and last 30 days. The admin surface returns 404 rather than 403 so it isn't discoverable.
- **Backend test coverage is strong**, and specs pin the non-obvious invariants (partial unique indexes matching model validations, monotonic read stamps, the free-registration tripwire in the abandonment sweep).

---

## Suggested order

1. **Reconcile with ABA before discarding** (#1) — money, and the smallest fix on this list.
2. **Alarms and an SNS topic** (#4) — a few hours, and it changes how you learn about everything else.
3. **Scrub chat on account deletion** (#2) and **decide the retention window** (#3) — same area, do them together.
4. **`tsc --noEmit` in CI** (#6) — one job, immediate value.
5. **Verify cross-task fan-out, then go to two tasks** (#5).
6. Backfill frontend tests on the payment and registration flows as you touch them.

---

## Method and limits

Verified by reading current source and Terraform rather than trusting the previous audit: `infrastructure/{database,ecs,variables}.tf` and `terraform.tfvars`, `.github/workflows/{ci,deploy}.yml`, `config/recurring.yml`, `config/initializers/rack_attack.rb`, `config/brakeman.ignore`, `app/services/registrations/release_abandoned.rb`, `app/services/aba_payway/client.rb`, `app/models/user.rb`, `frontend/src/routes/privacy.tsx`, and spec/test file counts on both sides.

**Not verified, and worth confirming yourself:** whether `VITE_SENTRY_DSN` is actually set as a GitHub repository variable (the workflow references it, but I can't see repo settings); whether "Required reviewers" is configured on the `production` GitHub environment, without which the deploy gate is inert; and current RDS/ECS runtime metrics. No backend code was executed for this audit — the sandbox has Ruby 3.0 against a project requiring 4.0.1, so findings come from reading rather than running.
