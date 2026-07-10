# Rally — Production Readiness Audit

*Prepared 2026-07-10*

## Executive summary

Rally has a solid, well-architected core: event creation, registration with capacity enforcement, custom event types (5K/10K/etc.), registration surveys, organizer dashboards, and clean auth/authorization patterns backed by a decent test suite for the main flows. Infrastructure (Terraform on AWS: ECS, RDS, S3/CloudFront, Secrets Manager) is genuinely production-grade in design.

The platform is **not** ready to launch to paying users today for one overriding reason: **there is no real payment processing**. Registrations track a price and a payment status, but no money actually moves — organizers must collect payment out-of-band and manually mark registrations paid. Beyond that, there's no transactional email (no confirmation, no password reset, no reminders), no way to recover a forgotten password, no email verification, and no admin/moderation layer. These are the items that separate "working demo" from "product we can put in front of real users."

Below: what exists today, then what's missing, grouped by how blocking it is.

## What's already built

**Core event & registration flow.** Organizers create events (title, description, category, location, date/time, capacity, banner/logo, brand color) with optional per-type sub-events (e.g. 5K vs 10K, each with its own price and capacity) and an optional custom registration survey (text/single-choice/multi-choice questions). Participants browse published events, register, optionally pick event types and answer the survey, and get a downloadable `.ics` calendar file and a shareable QR code. Capacity is enforced correctly at both the event and event-type level, on the model layer.

**Organizer dashboard.** Creators see a management view per event: participant list with payment-status badges and manual mark-paid/unpaid, per-type registration breakdown, revenue total, branding editor, and survey response viewer grouped by question. A separate dashboard lists "events I'm participating in" vs. "events I created."

**Auth & authorization.** Stateless JWT auth (30-day tokens), bcrypt password hashing, correctly scoped authorization (only an event's creator can edit/delete it, view its registrant list, or manage its survey) — the backend audit found no broken-access-control gaps across any endpoint.

**API & data layer.** Rails API with sensible `includes()` usage (no obvious N+1 issues), money handled correctly as `*_cents` integers, foreign keys indexed, request specs covering auth/events/registrations with both happy-path and authorization edge cases.

**Infrastructure.** Terraform provisions a real production topology: ECS Fargate behind an ALB, RDS Postgres (encrypted, automated backups, deletion protection), S3 + CloudFront for the frontend with SPA routing, Secrets Manager for `DATABASE_URL`/`JWT_SECRET`/`RAILS_MASTER_KEY` (nothing hardcoded), conditional ACM/Route 53 for custom domains, and CI that runs RuboCop, Brakeman, bundler-audit, and RSpec on every change.

## What's missing — grouped by urgency

### Blocking (must exist before any real users pay to attend an event)

- **Payment processing.** No Stripe/PayPal/any processor is integrated anywhere in the codebase (confirmed by search — no references in either Gemfile or package.json). `payment_status` is a field an organizer sets by hand. Until this exists, the product can only really support free events, or events where the organizer handles money entirely outside the app.
- **Password reset.** No "forgot password" endpoint or UI exists at all. A locked-out user has no recovery path.
- **Transactional email.** `ApplicationMailer` exists but has no mailers implemented, and production SMTP is unconfigured (`config/environments/production.rb` has it commented out). No registration confirmation, no organizer notification of new signups, no event reminders, no cancellation emails. For an events product, participants expect an email confirmation at minimum.
- **Email verification.** Signup logs a user in immediately with no confirmation step, so there's no guarantee an email address is real or owned by the signer-upper.

### Important (should be fixed before a public launch, even if soft)

- **Event editing.** Once created, an organizer can only edit branding — not the title, date, description, capacity, or price. Any real-world event will need a correction at some point.
- **No admin/moderation tooling.** No admin role, no way to remove abusive content, suspend a user, or intervene in a dispute. For a public platform this is a real operational and trust/safety gap.
- **No search, filter, or pagination on the events list.** `GET /events` returns every published upcoming event unpaginated — fine at low volume, but both a UX gap (no way to find an event by category/location/keyword) and a scaling risk.
- **Rate limiting.** No Rack::Attack or equivalent on the API — signup/signin and registration endpoints are open to abuse/credential stuffing.
- **Frontend test coverage is zero**, and the CI "Jest" job runs `npm test` against a `package.json` with no `test` script and no testing library installed — it currently passes only because of `--passWithNoTests`. It provides no real regression protection (this matches what `CLAUDE.md` already flags).
- **Backend test gaps.** Surveys, survey responses, uploads, and event-type-specific logic have no request/model specs, versus solid coverage on auth/events/registrations.
- **Observability.** No error tracking (Sentry/Honeybadger), no alerting on ECS/RDS health, no APM. Right now a production incident would be discovered by a user complaint, not a dashboard.
- **RDS Multi-AZ is disabled** and desired ECS task count defaults to 1 — no redundancy if the single instance/task dies.
- **CI/CD has no deploy approval gate** — merging to `main` deploys straight to production.
- **Leftover Supabase/Lovable scaffolding** in `src/integrations/` is unused dead code (confirmed — imported but never invoked) and should be removed before launch to avoid confusion and unused env-var requirements.

### Worth doing, not launch-blocking

- Waitlists for full events; refund workflow (the `refunded` status exists but nothing drives it); CSV export of registrants; check-in/attendance tracking; results/leaderboard posting; survey response analytics beyond a raw list.
- Profile/account settings page (change email, password, avatar) — currently profile is read/update via API but there's limited UI for it.
- SEO: sitemap only includes `/` and `/auth` (missing `/events` and individual event pages); event detail pages use a generic title/description instead of the event's own; no per-event Open Graph image.
- Database backup retention is 7 days with no cross-region copy — fine to start, worth extending as the user base grows.
- Soft deletes / audit trail — everything is a hard delete today, so there's no recovery from an accidental removal and no history for disputes.
- Google OAuth is present in the UI but explicitly disabled ("not yet available").

## Suggested sequencing

1. **Payments + email (confirmation, password reset, verification)** — these two alone are what make the app usable by real, unaffiliated users rather than a closed pilot with an organizer who trusts the honor system.
2. **Event editing, rate limiting, error tracking, admin basics** — the minimum operational safety net for a public launch.
3. **Search/pagination, remaining test coverage, Multi-AZ/redundancy, CI approval gate** — hardening once there's real traffic.
4. **Waitlists, refunds, exports, analytics, SEO polish** — iterate post-launch based on organizer feedback.

---

*Method note: this audit was compiled by reviewing the Rails backend (models, controllers, auth, jobs, mailers, specs), the TanStack Start frontend (routes, auth flow, API client, components), and the Terraform/CI/CD infrastructure, then spot-verified directly (payment integration search, `seeds.rb`, `package.json` test tooling, CI Jest job wiring).*
