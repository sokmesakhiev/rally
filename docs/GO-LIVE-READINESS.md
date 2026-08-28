# Rally — Go-Live Readiness Assessment

**Assessed:** 28 August 2026
**Question:** Can we ship this to real end users, handling real money?

---

## Verdict

**Yes — but not this week, and not as a wide-open public launch.**

The product is functionally complete and the engineering is in genuinely good shape. What stands between Rally and real users is not missing features. It's a short list of **legal, operational, and verification** items — several of which are external dependencies with lead times measured in days, not hours.

**Recommended path: a controlled pilot with 1–3 known organizers running small real events**, then open signups once that's proven. The blockers below are ordered accordingly.

---

## What's genuinely ready

These aren't aspirations — they're verified in the codebase.

**Feature completeness.** Registration, guest checkout by phone-or-email, KHQR payments, refunds, waitlists with automatic promotion, check-in scanning, results import and leaderboards, PDF certificates, custom surveys, team roles, CSV export, bilingual UI, admin moderation with an audit trail. This is a complete product, not an MVP skeleton.

**Backend test coverage.** 808 RSpec examples across models, requests, services, and jobs — covering the money paths (payments, refunds, plan payments, webhooks), the authorization matrix, and the edge cases that matter (capacity races, waitlist promotion, guest account matching).

**Security posture.**
- Stateless JWT auth, per-action authorization via a single audited `EventAuthorization` concern
- Rack::Attack rate limiting with a shared cache store
- reCAPTCHA v3 on signup
- Google ID tokens verified server-side, never trusted from the client
- Organizer PayWay API keys encrypted at rest, never returned in full
- Admin surface returns 404 to non-admins rather than advertising itself
- Payment webhooks treated as untrusted triggers only — actual status always confirmed via authenticated server-to-server Check Transaction. This is the correct design and a common thing to get wrong.

**Infrastructure.** RDS encrypted at rest, 7-day automated backups, deletion protection on, final snapshot on destroy, Multi-AZ defaulted to true. Sentry wired on both backend and frontend. Health check endpoint. Deploy is a repeatable GitHub Actions pipeline with a production approval gate.

**Code quality.** No TODOs or FIXMEs in application code. Decisions are documented inline with their reasoning.

---

## Blockers — must fix before real users

### 🔴 1. Terms of Service and Privacy Policy are unreviewed placeholders

The app ships legal pages carrying an explicit banner: *"Draft — pending legal review. This placeholder copy is not yet reviewed legal text and should not be relied on as binding."* Signup **requires** users to accept these terms.

You are about to take money from people and process their personal data under terms that say they aren't binding. This is the single hardest blocker: it's a legal exposure, not an engineering one, and no amount of code fixes it.

**Action:** Get both documents reviewed by a lawyer familiar with Cambodian consumer and data protection law. Budget 1–2 weeks. The mechanism (versioned acceptance, re-acceptance on version bump) is already built and works — you're only swapping the words.

### 🔴 2. Amazon SES is likely still in sandbox

Production mail goes through SES. In sandbox mode, SES only delivers to **pre-verified addresses** — meaning registration confirmations, payment receipts, and password resets silently fail to reach real participants.

**Action:** Verify the sending domain, configure SPF/DKIM/DMARC, and request production access. AWS approval typically takes ~24 hours but can take longer. Then send real test mail to Gmail, Outlook, and a local provider to confirm inbox placement, not spam.

### 🔴 3. Production PayWay credentials unproven end-to-end

`config/payway.yml` correctly pins production to the live PayWay URL, but the credentials come from environment variables. Nothing in the repo proves a real payment has completed against production PayWay.

**Action:** Run at least one **real, small-value transaction end to end** in production — generate KHQR, pay it with an actual banking app, confirm the webhook fires, confirm the registration flips to paid, then **issue a real refund** against it. Refunds additionally need `ABA_PAYWAY_RSA_PUBLIC_KEY` set, or they fail. Test refunds specifically — they're the path most likely to be discovered broken at the worst moment.

### 🔴 4. Zero frontend tests

The backend has 808 examples. The frontend has none — no test runner is even configured, and CI has a `jest` job with nothing to run. Every checkout flow, payment polling loop, and permission-gated control is verified only by hand.

This doesn't block a small supervised pilot, where you'd catch problems directly. It does block scaling, because you have no safety net against regressions in exactly the flows where a bug costs money.

**Action:** Before wide launch, add Vitest + Testing Library and cover the critical paths: registration submission, payment status polling, check-in scanning, and role-based UI gating. Wire the CI job to actually run them.

---

## High priority — fix during or immediately after pilot

### 🟠 5. Deploy race condition between frontend and backend

`deploy-frontend` and `deploy-backend` run in parallel. The frontend finishes in ~1 minute; the backend takes ~10 (Docker build, ECR push, ECS rollout, stabilization wait). On any deploy touching both, there's a multi-minute window where the new frontend is live against the old backend.

For a change like the recent `freeze` → `suspend` rename, that window means admin actions 404 and JSON fields read as `undefined`.

**Action:** Sequence the jobs (`deploy-frontend` needs `deploy-backend`) as an immediate mitigation. For genuinely breaking API changes, adopt expand/contract: ship the backend serving both old and new shapes, then the frontend, then remove the old shape in a later deploy. See the discussion in this repo's deploy notes.

### 🟠 6. No documented restore drill

Backups are enabled and retained 7 days. Nobody has verified a restore actually works. An untested backup is a hypothesis.

**Action:** Restore a snapshot into a scratch instance, confirm data integrity, and write down the runbook with timings. Do it once before launch, then quarterly.

### 🟠 7. No uptime alerting

Sentry catches application exceptions. Nothing alerts you if the ECS service is down, the database is unreachable, or the site returns 502 — Sentry sees errors, not absence.

**Action:** Point an uptime monitor at `/up` with alerting to the same Telegram channel the deploy pipeline already uses. Add CloudWatch alarms for ECS task count, RDS CPU, and connection count.

### 🟠 8. Admin bootstrapping is undocumented

Admin is granted from the Rails console only — a deliberate, correct security decision. But there's no written runbook for how to do it against production ECS, which becomes urgent the first time you need to suspend a fraudulent event at 11pm.

**Action:** Document the exact `aws ecs execute-command` invocation to open a production console and grant admin. Test it before you need it.

---

## Worth knowing, not blocking

### 🟡 9. Solid Queue runs inside Puma

Background jobs (emails, certificate generation, webhook processing) run in the web server process. Correct call at current scale — but a burst of certificate generation for a 10,000-person event will compete with web request handling.

**Watch for:** rising response times during post-event certificate sweeps. The fix (split into a dedicated ECS service) is a config flag away and documented in `CLAUDE.md`.

### 🟡 10. Free tier abuse surface

Anyone verified or not can create unlimited free events up to 20 participants. There's no per-user event cap.

**Watch for:** spam events. Moderation tooling exists to handle it reactively; add a cap if it becomes a pattern.

### 🟡 11. `db.t3.micro` default

Fine for a pilot. Undersized for a 10,000-person event's registration rush. Both instance class and Multi-AZ are Terraform variables — plan to size up before any large event opens registration.

### 🟡 12. Certificate generation is unbounded

`GenerateCertificatesJob` sweeps eligible registrations. For a very large event this is a lot of PDF rendering in one pass, in the same process as the web server (see #9).

**Watch for:** memory pressure on large events. Consider batching.

---

## Recommended launch sequence

**Week 1 — unblock the externals (start today, they have lead times)**
- Send Terms & Privacy to legal review
- Request SES production access; configure SPF/DKIM/DMARC
- Sequence the deploy jobs (small change, removes a live footgun)

**Week 2 — prove the money path**
- Real production payment + real refund, end to end
- Backup restore drill, documented
- Uptime monitoring and CloudWatch alarms
- Write the admin bootstrap runbook

**Week 3 — controlled pilot**
- 1–3 known organizers, small real events, ideally free or low-value first
- You watch every registration and payment personally
- Fix what surfaces

**Week 4+ — open up**
- Add frontend tests for critical paths
- Size infrastructure for expected load
- Open public organizer signups

---

## Bottom line

Rally is closer to launch than most products at this stage, and notably better engineered than typical — the payment design, authorization model, and moderation tooling all reflect real thought about failure modes and abuse.

The gap is not the product. It's that **a platform handling other people's money and personal data needs its legal footing, its email delivery, and its payment path proven in production** — none of which are code problems, and all of which have external lead times.

Start the legal review and the SES request today. Those two clocks are the ones actually gating your launch date.
