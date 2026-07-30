# Rally — Production Readiness Audit

*Prepared 2026-07-10 · Updated 2026-07-30*

## Executive summary

**Update (2026-07-30):** every item that was blocking launch in the original audit has been resolved. Payment processing is real (a custom ABA PayWay/KHQR integration, both attendee registration payments and organizer publish-plan payments, backed by webhook verification and a background job), password reset and email verification both work end to end, and transactional email is wired through Solid Queue to SES in production. Rally can now support real, unaffiliated paying users rather than only a closed pilot running on the honor system.

What's left is the "important, should fix before a public launch" tier from the original audit — most of it untouched: no admin/moderation tooling, no rate limiting, no error tracking/observability, the public events list still has no pagination or search, frontend test coverage is still effectively zero, and RDS/ECS still run single-instance with no deploy approval gate. One item is *partially* done in a way worth calling out specifically: the backend now supports editing a full event (title, date, description, capacity, price), but the frontend's manage-event page still only exposes editing branding (color/banner/logo) — so from an organizer's actual experience, event editing is still not fixed.

*(Original summary, for reference: "Rally has a solid, well-architected core... The platform is not ready to launch to paying users today for one overriding reason: there is no real payment processing... Beyond that, there's no transactional email, no way to recover a forgotten password, no email verification.")*

## What's already built

**Core event & registration flow.** Unchanged from the original audit — organizers create events with optional per-type sub-events and custom surveys; participants browse, register, get a `.ics` file and a QR code; capacity is enforced at both the event and event-type level.

**Payments (new since the original audit).** `AbaPayway::Client` is a hand-rolled KHQR gateway client (`app/services/aba_payway/`), used by two independent flows: `Payments::CreatePayment` for attendee registration payments (organizer receives the money, via the organizer's own PayWay credentials on `Profile` when connected, falling back to Rally's platform credentials), and `EventPlanPaymentsController` for the organizer's "pay to publish" plan fee (always Rally's own credentials). Both generate a KHQR QR code synchronously (the frontend needs it immediately to render), then confirm payment two ways: the frontend polls `GET /payments/:id` / `GET /plan_payments/:id` (re-checking with ABA at most once every 5s), and ABA's webhook (`Webhooks::AbaPaywayController`) triggers a background job (`ProcessAbaPaywayWebhookJob`) that does the real, authenticated Check Transaction call and updates status — the webhook payload itself is never trusted directly, and the controller now just acks immediately instead of blocking the response on an outbound call to ABA.

**Password reset & email verification (new).** `PasswordResetsController` (request + token-based reset, 2-hour expiry) and `EmailVerificationsController` (resend + confirm) are both implemented, backend and frontend, with full request-spec coverage.

**Transactional email (new).** `UserMailer` (password reset, email verification) and `RegistrationMailer` (registration confirmation, payment received) are implemented and used from every relevant controller action via `deliver_later`. Production delivery goes through Amazon SES (`config/environments/production.rb`, IAM-role auth, no access keys), and Solid Queue actually processes these jobs in production (`SOLID_QUEUE_IN_PUMA=true` runs the queue supervisor inside the same Puma process) — this is presently the only thing exercising the job queue for real.

**Google OAuth (upgraded from "present but disabled").** Full "Sign in with Google" flow — Google Identity Services on the frontend, server-side ID-token verification (`Google::Auth::IDTokens.verify_oidc`) on the backend, account linking by email — gated behind `VITE_GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_ID` being configured.

**Event editing — backend only (new, partial).** `EventsController#update` now validates and persists the full event shape (title, description, category, dates, location, price, event types) via `EventUpdateRequestSchema`, not just branding. There is no frontend UI for this yet — see "What's missing."

**Request-schema validation layer (new).** Every controller action that accepts params now validates its shape via `dry-validation` request schemas before touching the model layer, with model validations kept as the sole source of truth for business rules that apply across every write path (not just the one HTTP endpoint).

**Query performance (new).** Fixed a real N+1 on the public events listing (`GET /api/v1/events`): `EventType#spots_remaining`/`#full?` were calling `.count`, which always issues a fresh query even against a preloaded association — swapped to `.size` plus proper eager-loading.

**Organizer dashboard, auth/authorization, API/data layer, infrastructure.** Unchanged from the original audit — still accurate as written there.

## What's missing — grouped by urgency

### Blocking (must exist before any real users pay to attend an event)

**None.** All four items from the original audit — payment processing, password reset, transactional email, email verification — are resolved (see above).

### Important — all addressed (2026-07-30)

Every item in this tier has now been implemented. What was done, in the order the original list had them:

- **Event editing UI** — `EventDetailsEditor` (`frontend/src/components/event-details-editor.tsx`), mounted on the manage-event page, edits title, description, category, location, route link, start/end and price. Deliberately omits `capacity`/`plan`/`is_published`, which are owned by the publish flow and rejected server-side, so no field silently does nothing. Converts local wall-clock times correctly rather than via `toISOString().slice()`, which would have shifted every displayed time by the viewer's UTC offset.
- **Admin/moderation** — `User#admin` plus `suspended_at`/`suspension_reason`; `Api::V1::Admin::{Base,Users,Events}Controller` with user list/search/filter, suspend/unsuspend, and event list/unpublish/delete; a `/admin` frontend console with both tables and confirm dialogs. Suspension is enforced in `ApplicationController#authenticate_user!` on **every** request, not just at sign-in, because JWTs here are stateless and valid for 30 days. Non-admins get 404 rather than 403 so the surface isn't discoverable. Admin is granted from the console only — there is no promote-to-admin endpoint. Suspending unpublishes the user's events but leaves their own registrations alone (a refund decision, not a moderation one); event deletion requires `confirm=true` and is refused outright when paid registrations exist.
- **Search, filter, pagination** — `GET /api/v1/events` now takes `q`/`category`/`page`/`per_page` via `EventIndexRequestSchema` and returns a `meta` envelope. Search is ILIKE over title/description/location with `sanitize_sql_like` so `%` and `_` are literal. The frontend has a debounced search box, category chips, and pager. Added a composite `(is_published, start_at)` index plus one on `category`.
- **Rate limiting** — `rack-attack` with per-IP and per-email throttles on signin (two timescales), signup, password reset, email verification, registration creation, and uploads; the ABA webhook and health check are safelisted. Disabled in the test env by default (it would otherwise turn ordinary auth specs into spurious 429s) with opt-in via a `:rack_attack` tag.
- **Frontend tests** — Vitest + React Testing Library, 32 tests across `event-utils`, `api-client` (the backend contract: auth headers, error unwrapping, the `code` field), and `EventTypeSelector` (capacity rules). The CI job is renamed `jest` → `vitest`, uses `npm ci`, and no longer passes `--passWithNoTests`, which is what let it report success on a nonexistent suite.
- **Backend test gaps** — added `spec/requests/{survey_responses,uploads,admin,rate_limiting}_spec.rb` and `spec/models/{event_type,survey,event_plan_payment}_spec.rb`. `Survey` covers `SurveyQuestion` and `RegistrationAnswer` too.
- **Observability** — `sentry-ruby`/`sentry-rails` gated on `SENTRY_DSN`, with routine 404s/bad requests excluded, health checks dropped from tracing, `send_default_pii = false`, and user id (not email) attached per request. Frontend `@sentry/react` gated on `VITE_SENTRY_DSN`, replacing `lovable-error-reporting.ts` — which posted to a `window.__lovableEvents` hook that only exists inside Lovable's preview, so in real deployments it silently did nothing.
- **Redundancy** — `db_multi_az` variable defaulting to `true`; `ecs_desired_count` default raised 1 → 2.
- **Deploy approval gate** — both deploy jobs declare `environment: production`. Note this is only half the gate: it does nothing until "Required reviewers" is configured on that environment in GitHub's settings.
- **Supabase/Lovable scaffolding** — `frontend/src/integrations/` deleted and the `@supabase/supabase-js` / `@lovable.dev/cloud-auth-js` deps dropped. This turned out to be more than dead code: `attachSupabaseAuth` was registered as a live global `functionMiddleware` in `src/start.ts`, and the `supabase` proxy **throws** when `VITE_SUPABASE_URL` is unset — so any TanStack serverFn RPC would have failed in production. `@lovable.dev/vite-tanstack-config` was deliberately **kept**: contrary to the original audit's framing of this directory as uniformly unused, that package supplies the entire Vite config and removing it breaks the build.

Two things the original audit got slightly wrong, corrected here for the record: `package.json` did have a `test` script (`jest --passWithNoTests`, plus `jest` as a runtime dependency), and the Lovable/Supabase material was not uniformly dead (see the two points above).

### Newly noted (2026-07-30)

- **`npm run lint` is broken repo-wide.** `package.json` pins `typescript: ^7.0.2`, and typescript-eslint refuses to run against TS 7 ("does not support TS 7.0"). This predates this pass and is unrelated to it, but it means the `scan_js`/lint path currently can't run at all — either pin TypeScript back to 6.x or wait for typescript-eslint's TS 7 support.
- **Sentry `release` is unset in production.** `config.release` reads `GIT_SHA`, which nothing sets: the ECS task definition is Terraform-managed with `ignore_changes` on `container_definitions` and always points at `:latest`, so a deploy force-pulls that tag rather than registering a revision CI could inject the SHA into. Errors will group under a single release until that changes. The frontend does get a real release (`VITE_GIT_SHA` at build time).

### Worth doing, not launch-blocking

Unchanged from the original audit — spot-checked and none of this has moved: waitlists, refund workflow (the `refunded` status still exists on both `Payment` and `Registration` but nothing drives it), CSV export, check-in/attendance tracking, results/leaderboard, survey response analytics, profile/account settings UI, SEO (sitemap still only lists `/` and `/auth`), backup retention/cross-region copy, soft deletes/audit trail.

## Suggested sequencing

The blocking and important tiers are both done. What's left before launch is verification and configuration rather than new development:

1. **Run the suites.** `bundle install` (rack-attack and Sentry are new Gemfile entries) then `bundle exec rspec` and `bin/rubocop`; `npm run test` on the frontend. None of the backend work in this pass has been executed — see the caveat below.
2. **Configure what the code now expects.** Set `SENTRY_DSN`/`VITE_SENTRY_DSN`, turn on "Required reviewers" for the `production` GitHub environment (without it the deploy gate is inert), run the two new migrations, and grant yourself admin via `User.find_by(email: ...).update!(admin: true)`.
3. **Fix the lint blocker** — TypeScript 7 vs. typescript-eslint (see "Newly noted" above).
4. **Waitlists, refunds, exports, analytics, SEO polish** — iterate post-launch based on organizer feedback.

## Caveat on verification

The sandbox this work was done in has no network access to rubygems.org and no bundler, so **no backend code in this pass has been executed** — Ruby files were syntax-checked with `ruby -c` only. That covers syntax but not behavior, and specifically not: the new `dry-validation` schemas' predicates (`included_in?`, `gt?`, `lteq?`, `max_size?`), whether rack-attack's railtie inserts its middleware as assumed, the Sentry initializer's config keys, the ActiveRecord scopes and `left_joins`/`group` query in the admin users index, or any of the ~90 new spec examples. Frontend work *was* executed: typecheck passes (bar pre-existing `src/components/ui/` errors) and all 32 Vitest tests pass. Treat the backend as "written and reviewed, not yet run."

---

*Method note (2026-07-30 update): re-verified every item from the original audit against the current codebase — grepped/read the payment services and webhook/job code, mailers and production mail config, password-reset/email-verification controllers, Google OAuth wiring, the events controller and frontend manage-event page (to check UI vs. backend parity on editing), Gemfile (for rate-limiting/observability gems), `spec/requests` and `spec/models` directory listings, `infrastructure/database.tf` and `ecs.tf`, `.github/workflows/deploy.yml`, `frontend/src/integrations/`, and the sitemap route — rather than re-deriving conclusions from memory of what had been worked on.*

*Original method note, for reference: this audit was compiled by reviewing the Rails backend (models, controllers, auth, jobs, mailers, specs), the TanStack Start frontend (routes, auth flow, API client, components), and the Terraform/CI/CD infrastructure, then spot-verified directly (payment integration search, `seeds.rb`, `package.json` test tooling, CI Jest job wiring).*
