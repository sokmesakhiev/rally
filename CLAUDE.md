# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

"Rally" is an event registration platform (running/cycling/swimming/triathlon/etc.) with three parts:

- `backend/` — Rails 8.1 API-only app (Ruby 4.0.1, PostgreSQL, RSpec)
- `frontend/` — TanStack Start (React 19, file-based routing, Vite, Tailwind v4, shadcn/ui)
- `infrastructure/` — Terraform for AWS (ECS backend, S3+CloudFront frontend)

The backend and frontend are deployed independently; CI (`.github/workflows/ci.yml`) only runs a subproject's jobs when files under that subproject changed.

## Commands

### Backend (run from `backend/`)

```
bin/setup                          # install gems, prepare db
bin/rails server -p 3000           # run the API (default port 3000)
bin/rails db:create db:migrate db:seed

bundle exec rspec                  # run the whole test suite
bundle exec rspec spec/models/event_spec.rb        # single file
bundle exec rspec spec/models/event_spec.rb:42      # single example at a line

bin/rubocop                        # lint (Omakase Rails style)
bin/rubocop -A                     # autocorrect
bin/brakeman                       # static security scan
bin/bundler-audit                  # dependency vulnerability scan
```

RSpec is the real test suite (factories in `spec/factories`, request specs in `spec/requests`, model specs in `spec/models`). `backend/test/` is unused default Rails/Minitest scaffolding — don't add tests there.

### Frontend (run from `frontend/`)

```
bun install   (or npm install)
bun run dev          # vite dev server, default port 5173
bun run build         # production build (outputs to dist/, deployed to S3)
bun run lint          # eslint
bun run format        # prettier --write .
```

There is no configured test runner for the frontend (no `test` script, no Jest/Vitest config) despite a `jest` job existing in `ci.yml` — that CI job currently has nothing to run.

## Architecture

### Backend: Rails API, JWT auth, no sessions

- All routes are namespaced under `/api/v1` (`config/routes.rb`), controllers live in `app/controllers/api/v1/`.
- Auth is stateless JWT (`lib/json_web_token.rb`), not Rails sessions/Devise. `ApplicationController#authenticate_user!` reads `Authorization: Bearer <token>`, decodes it, and sets `@current_user`. Add `before_action :authenticate_user!` per-action (see `EventsController`) rather than app-wide, since browsing events is public.
- Authorization is manual per-controller (e.g. `EventsController#authorize_creator!` checks `@event.creator_id == current_user.id`) — there is no Pundit/CanCanCan.
- Controllers hand-build JSON response hashes (`event_json`, `user_payload`, etc.) rather than using serializers/jbuilder — follow that pattern when adding endpoints.
- File uploads (banner/logo/avatar images) go through `Api::V1::UploadsController`, which validates content-type/size and stores via Active Storage (`has_one_attached` on `Event`/`Profile`), not a custom S3 client. Storage backend is Disk locally/test, S3 (`amazon`) in production via ECS IAM role (`config/storage.yml`).

### Backend: domain model

Core relationships (see `app/models/`):

- `User` has one `Profile`, many `Event`s (as creator), many `Registration`s, many `Survey`s (as creator).
- `Profile` holds display name/avatar plus an organizer's own ABA PayWay merchant credentials (`payway_merchant_id`, encrypted `payway_api_key`) — see "Backend: payments" below.
- `Event` belongs to a creator (`User`) and optionally one `Survey`; has many `EventType`s (e.g. "5K", "10K" sub-races with their own capacity/price) and many `Registration`s and `EventPlanPayment`s.
- `Registration` joins a `User` to an `Event`, and through `RegistrationEventType` to the specific `EventType`(s) chosen. Capacity enforcement happens in model validations (`Registration#event_not_full`, `RegistrationEventType#event_type_not_full`), not at the DB or controller layer — both add a machine-readable `errors.add(:base, :event_full, ...)`, which the relevant controller maps to `code: "full"` in the JSON error response so the frontend can react (lock the UI, refresh capacity) instead of string-matching the message.
- `Survey`/`SurveyQuestion`/`RegistrationAnswer`: an organizer attaches an optional survey to an event; `SurveyQuestion.options` and `RegistrationAnswer.answer_options` are `jsonb` arrays of `{id, label}`; validity of selected option IDs is checked in `RegistrationAnswer#valid_options_selected`.
- Money is always stored as `*_cents` integers; an `EventType#effective_price_cents` falls back to the parent event's price when the type has no price of its own.

When changing pricing/capacity logic, check both the `Event`-level and `EventType`-level paths — most events support both a single flat price/capacity and per-type overrides. Also check `Event#combined_event_type_capacity` (sum of each type's own capacity) against `Event::PLANS[plan][:capacity]` — publishing under a plan too small for the event's types is rejected server-side (`Event#capacity_covers_event_types`) before any payment is attempted, not just disabled client-side.

### Backend: publishing & payments (ABA PayWay / KHQR)

Two separate payment flows share one gateway (`app/services/aba_payway/client.rb`), and it's easy to conflate them:

- **`Payment`** — an attendee paying to register for an event. Created per-`Registration`.
- **`EventPlanPayment`** — an organizer paying Rally to *publish* an event under one of `Event::PLANS` (`free`/`small`/`medium`/`large`/`extra_large`, each with a fixed `capacity` and `price_cents`). `EventPlanPayment#mark_paid!` is what actually sets `event.is_published = true` and stamps the event's `plan`/`capacity`. The free tier publishes immediately with no pending payment to poll.

Gateway credentials are two-tiered:

- **Platform defaults** live in `config/payway.yml` (per-environment, `ERB`-evaluated, same `Rails.application.config_for` pattern as `config/database.yml`) — these are Rally's own PayWay account and are what `EventPlanPayment`s always use, and what `Payment`s fall back to.
- **Per-organizer credentials** live encrypted on `Profile` (`payway_merchant_id` / `payway_api_key`, via Active Record encryption). When `Profile#payway_configured?` is true, that organizer's own event registration payments route through their credentials instead of the platform default — see `AbaPayway::Client.for_event`. `ProfilesController#profile_json` only ever exposes `payway_api_key_masked`, never the real key.

### Frontend: TanStack Start file-based routing

- Routing follows `src/routes/README.md` conventions: every file in `src/routes/` is a route, `$id` for dynamic segments, `_layout.tsx` for layout routes, `__root.tsx` is the app shell. `routeTree.gen.ts` is generated — never hand-edit it.
- `src/routes/_authenticated/` is a layout route gating dashboard pages behind auth (`route.tsx` checks auth state before rendering children).
- All backend communication goes through `src/lib/api-client.ts`, a hand-written fetch wrapper (not React Query directly, though `@tanstack/react-query`'s `QueryClient` is wired into the router context). It reads `VITE_API_URL` (defaults to `http://localhost:3001` — note this differs from the Rails default port 3000, so set `VITE_API_URL=http://localhost:3000` or run Rails on 3001 locally) and stores the JWT in `localStorage` under `rally_token`. `src/lib/use-auth.tsx` wraps this in an `AuthProvider`/`useAuth()` context.
- `src/integrations/supabase/` and `src/integrations/lovable/` are leftovers from this project's Lovable/Supabase scaffold origin (auto-generated, "do not modify" headers) and are largely vestigial — real app data and auth flow through the Rails API via `api-client.ts`/`use-auth.tsx`, not Supabase queries. Don't extend the Supabase path for new features.
- UI components in `src/components/ui/` are shadcn/ui primitives — prefer composing these over adding new UI libraries. These are treated as vendored/out-of-scope for app-specific work (e.g. i18n) the same way `src/components/ui/chart.tsx` already had pre-existing, unrelated TS errors before any of this session's work.
- `SiteHeader` (`src/components/site-header.tsx`) renders a "Welcome, {name}" avatar dropdown (Edit profile / Payment settings / Sign out) once logged in, replacing a plain sign-out button; `use-auth.tsx`'s `refresh()` is called after profile saves so the header updates immediately. The dropdown's "Payment settings" item deep-links to `profile.tsx`'s `#payment-settings` anchor.

### Frontend: i18n (English + Khmer)

The frontend is fully wired for translation via `i18next`/`react-i18next` — every user-facing string in `src/routes/` and `src/components/*.tsx` (excluding `src/components/ui/` shadcn primitives) goes through `t("namespace.key")`, not hardcoded literals.

- `src/lib/i18n.ts` initializes the i18next singleton and exports `SUPPORTED_LANGUAGES` (`en`, `km`), `setLanguage()`, and `applyStoredLanguage()`. **It always boots to English on both server and the client's first render** — TanStack Start does SSR, so applying a stored language preference synchronously would cause a hydration mismatch. The stored preference (`localStorage["rally_lang"]`) is only applied client-side, in a `useEffect` in `__root.tsx`, after mount.
- Locale files are `src/i18n/locales/en.json` (source of truth) and `src/i18n/locales/km.json` (Khmer), namespaced roughly one-per-route/component (`header`, `home`, `auth`, `eventDetail`, `dashboard`, `manageEvent`, `eventForm`, `profile`, `surveyBuilder`, etc.). Keep both files in lockstep — every key added to `en.json` needs a `km.json` counterpart, or the UI silently falls back to the English string when `km` is active.
- `LanguageSwitcher` (`src/components/language-switcher.tsx`) is the globe-icon control in `SiteHeader`; it calls `setLanguage()`, which updates `localStorage`, `i18n.changeLanguage()`, and `document.documentElement.lang`.
- Non-component code that needs translated strings (e.g. `src/lib/event-utils.ts`'s `formatPrice`/`formatDate`/`categoryLabel`) imports the `i18n` default export directly and calls `i18n.t(...)` / reads `i18n.language`, rather than needing the `useTranslation()` hook — this only works because these functions are called synchronously inside a component's render body, so they naturally re-run on re-render after a language change.
- Zod validation schemas (`auth.tsx`, `forgot-password.tsx`, etc.) intentionally carry no error message strings (e.g. `z.string().min(8)`, not `.min(8, "...")`) — the translated message is chosen at the `safeParse` call site based on which check failed, since zod's own message API isn't translation-aware.
- Route `head()` meta (page `<title>`, SEO `<meta description>`) is deliberately left in English — it's not run through `t()`.
- `EVENT_CATEGORIES` (a `{value, label}[]` constant) no longer exists in `event-utils.ts`; use `eventCategoryOptions()` (a function, so it re-evaluates per-render/per-language) or the bare `EVENT_CATEGORY_VALUES` string array instead.

### Infrastructure

Terraform (`infrastructure/`) provisions: ECS (backend container), ECR, RDS-style database, S3+CloudFront (frontend static hosting), IAM, networking, secrets. `backend/config/deploy.yml` (Kamal) is unconfigured Rails-generated scaffolding (placeholder IP, local registry) — it is not the real deploy path and shouldn't be treated as one.

CD is `.github/workflows/deploy.yml`, triggered on push to `main`, gated by the same path-based change detection as CI (`dorny/paths-filter`, so a push only deploys the subproject(s) that actually changed):

- **`deploy-frontend`** — `npm run build`, then `aws s3 sync` to the frontend bucket and a CloudFront invalidation.
- **`deploy-backend`** — builds the `backend/Dockerfile` image for `linux/amd64` (Fargate), pushes it to ECR tagged `:${{ github.sha }}` and `:latest`, then `aws ecs update-service --force-new-deployment` and waits for the service to stabilize. This mirrors `scripts/deploy.sh --backend-only`, the manual/local equivalent (which additionally reads cluster/service/repo names from `terraform output` — CI can't do that since Terraform state isn't available there, so those are GitHub secrets instead). Migrations run automatically on container boot via `bin/docker-entrypoint` (`db:prepare`), not as a separate CD step. The ECS task definition always points at the `:latest` tag (`infrastructure/ecs.tf` → `var.rails_image_tag`, default `"latest"`) and Terraform ignores `container_definitions` after the first `apply`, so a deploy is just "push a new `:latest` and force ECS to re-pull it."

Both jobs read AWS credentials from the same `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` secrets. `deploy-backend` additionally needs `ECR_REPOSITORY` (repo name, e.g. `rally-production-api` — see `infrastructure/ecr.tf`'s `${local.prefix}-api`), `ECS_CLUSTER`, and `ECS_SERVICE` (both `${local.prefix}-cluster` / `${local.prefix}-api` by default — see `infrastructure/outputs.tf`) as repo secrets; the IAM credentials need ECR push + `ecs:UpdateService`/`ecs:DescribeServices` permissions on top of whatever the frontend job already requires.
