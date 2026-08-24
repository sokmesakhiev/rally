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
bun run dev          # vite dev server, default port 8080
bun run build         # production build (outputs to dist/client/, deployed to S3 — see vite.config.ts)
bun run lint          # eslint
bun run format        # prettier --write .
```

There is no configured test runner for the frontend (no `test` script, no Jest/Vitest config) despite a `jest` job existing in `ci.yml` — that CI job currently has nothing to run.

## Architecture

### Backend: Rails API, JWT auth, no sessions

- All routes are namespaced under `/api/v1` (`config/routes.rb`), controllers live in `app/controllers/api/v1/`.
- Auth is stateless JWT (`lib/json_web_token.rb`), not Rails sessions/Devise. `ApplicationController#authenticate_user!` reads `Authorization: Bearer <token>`, decodes it, and sets `@current_user`. Add `before_action :authenticate_user!` per-action (see `EventsController`) rather than app-wide, since browsing events is public.
- Two ways to get a JWT: email/password (`AuthController#signup`/`#signin`) and "Sign in with Google" (`AuthController#google`, `POST /api/v1/auth/google` with `{ id_token }`). The Google flow verifies the ID token server-side with `Google::Auth::IDTokens.verify_oidc(token, aud: ENV["GOOGLE_CLIENT_ID"])` (signature/expiry/issuer/audience) — the frontend only ever gets a token from Google Identity Services, it never sees or sets `GOOGLE_CLIENT_ID`'s matching secret because there isn't one (ID-token verification, not the redirect/authorization-code flow, so no client secret is needed at all). `User.find_or_create_from_google!` does the account matching: existing `google_uid` → sign in; no `google_uid` but a matching `email` → link Google to that password account; otherwise create a new account with a random unusable password (keeps `has_secure_password`'s NOT NULL `password_digest` invariant without schema special-casing). Gated behind `GOOGLE_CLIENT_ID` being set — see "Frontend: Google Identity Services sign-in" below for the matching frontend gate.
- `AuthController#signup` also runs `RecaptchaVerifier.verify` (`app/services/recaptcha_verifier.rb`) against an optional `recaptcha_token` param before creating the account, rejecting with `code: "recaptcha_failed"` on failure. Gated behind `RECAPTCHA_SECRET_KEY` — unset, `.verify` always returns a passing result, so signup works with no captcha check in dev/test/CI. Score threshold is `RecaptchaVerifier::MIN_SCORE` (0.5, Google's own suggested default for reCAPTCHA v3). See "Frontend: reCAPTCHA v3 on signup" below for the matching frontend gate.
- Authorization is manual per-controller (e.g. `EventsController#authorize_creator!` checks `@event.creator_id == current_user.id`) — there is no Pundit/CanCanCan.
- Controllers hand-build JSON response hashes (`event_json`, `user_payload`, etc.) rather than using serializers/jbuilder — follow that pattern when adding endpoints.
- File uploads (banner/logo/avatar images) go through `Api::V1::UploadsController`, which validates content-type/size and stores via Active Storage (`has_one_attached` on `Event`/`Profile`), not a custom S3 client. Storage backend is Disk locally/test, S3 (`amazon`) in production via ECS IAM role (`config/storage.yml`).

### Backend: domain model

Core relationships (see `app/models/`):

- `User` has one `Profile`, many `Event`s (as creator), many `Registration`s, many `Survey`s (as creator). `google_uid`/`provider` are set only for accounts that have signed in with Google at least once (see "Backend: Rails API, JWT auth, no sessions" above) — both are nullable, Postgres allows multiple NULLs under `google_uid`'s unique index, and a password-only account has neither.
- `Profile` holds display name/avatar plus an organizer's own ABA PayWay merchant credentials (`payway_merchant_id`, encrypted `payway_api_key`) — see "Backend: payments" below.
- `Event` belongs to a creator (`User`) and optionally one `Survey`; has many `EventType`s (e.g. "5K", "10K" sub-races with their own capacity/price) and many `Registration`s and `EventPlanPayment`s.
- `Registration` joins a `User` to an `Event`, and through `RegistrationEventType` to the specific `EventType`(s) chosen. Capacity enforcement happens in model validations (`Registration#event_not_full`, `RegistrationEventType#event_type_not_full`), not at the DB or controller layer — both add a machine-readable `errors.add(:base, :event_full, ...)`, which the relevant controller maps to `code: "full"` in the JSON error response so the frontend can react (lock the UI, refresh capacity) instead of string-matching the message.
- `Survey`/`SurveyQuestion`/`RegistrationAnswer`: an organizer attaches an optional survey to an event; `SurveyQuestion.options` and `RegistrationAnswer.answer_options` are `jsonb` arrays of `{id, label}`; validity of selected option IDs is checked in `RegistrationAnswer#valid_options_selected`.
- Money is always stored as `*_cents` integers; an `EventType#effective_price_cents` falls back to the parent event's price when the type has no price of its own.

When changing pricing/capacity logic, check both the `Event`-level and `EventType`-level paths — most events support both a single flat price/capacity and per-type overrides. Also check `Event#combined_event_type_capacity` (sum of each type's own capacity) against `Event::PLANS[plan][:capacity]` — publishing under a plan too small for the event's types is rejected server-side (`Event#capacity_covers_event_types`) before any payment is attempted, not just disabled client-side.

`Event#location` (free-text address) stays the source of truth for display; `latitude`/`longitude` are optional and only ever set by the frontend's Google Maps location picker (nil for events created before this existed, or when the picker fell back to plain text — see "Frontend: Google Maps location picker" below). `Event#lat_lng_present_together` enforces both-or-neither. `route_map_url` is just an optional link (e.g. a Google My Maps URL) for point-to-point events — there's no server-side route drawing/waypoints.

### Backend: publishing & payments (ABA PayWay / KHQR)

Two separate payment flows share one gateway (`app/services/aba_payway/client.rb`), and it's easy to conflate them:

- **`Payment`** — an attendee paying to register for an event. Created per-`Registration`.
- **`EventPlanPayment`** — an organizer paying Rally to *publish* an event under one of `Event::PLANS` (`free`/`small`/`medium`/`large`/`extra_large`, each with a fixed `capacity` and `price_cents`). `EventPlanPayment#mark_paid!` is what actually sets `event.is_published = true` and stamps the event's `plan`/`capacity`. The free tier publishes immediately with no pending payment to poll.

Gateway credentials are two-tiered:

- **Platform defaults** live in `config/payway.yml` (per-environment, `ERB`-evaluated, same `Rails.application.config_for` pattern as `config/database.yml`) — these are Rally's own PayWay account and are what `EventPlanPayment`s always use, and what `Payment`s fall back to.
- **Per-organizer credentials** live encrypted on `Profile` (`payway_merchant_id` / `payway_api_key`, via Active Record encryption). When `Profile#payway_configured?` is true, that organizer's own event registration payments route through their credentials instead of the platform default — see `AbaPayway::Client.for_event`. `ProfilesController#profile_json` only ever exposes `payway_api_key_masked`, never the real key.

### Backend: background jobs & cache (Solid Queue / Solid Cache)

`config/environments/production.rb` sets `config.active_job.queue_adapter = :solid_queue` and `config.cache_store = :solid_cache_store`, and `config/database.yml` has matching `queue`/`cache` roles (plus `cable`, unused — see below) pointed at separate databases on the same RDS instance as `primary` (same `url: ENV["DATABASE_URL"]`, just an overridden `database:` name — the standard Rails multi-database-on-one-server pattern). The `solid_queue`/`solid_cache` gems themselves live in Gemfile's `:production` group — development/test use the in-memory/null adapters instead (`config/environments/development.rb`, `test.rb`), so nothing extra is needed to run specs or `bin/rails server` locally.

- **Single-server job processing, not a separate worker service.** `config/puma.rb` has `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` — Solid Queue's supervisor runs *inside* the same Puma process as the web server when that env var is set (`infrastructure/ecs.tf` sets it to `"true"`), rather than a second ECS service/task running `bin/jobs`. This is the right tradeoff at this app's job volume; if job throughput ever needs to scale independently of web traffic, that's the point to split it into its own ECS service instead of flipping this flag.
- `db:prepare` (run automatically on container boot, see `bin/docker-entrypoint`) creates and schema-loads all databases declared under `production:` in `database.yml`, including `cable` — even though `cable.yml`/`db/cable_schema.rb` are unused leftovers from `rails new`'s default scaffolding (this is an API-only app, `config/application.rb` never requires `action_cable/railtie`, and there's no `solid_cable` gem). Harmless (just an extra empty database), but don't mistake its presence for ActionCable actually being wired up.
- `config/recurring.yml` schedules `SolidQueue::Job.clear_finished_in_batches` hourly in production — the only recurring job configured today. `app/jobs/` otherwise only has the empty `ApplicationJob` base class; nothing in the app enqueues background jobs yet (mailers use `deliver_later`, which is what actually exercises this adapter).

### Frontend: Google Identity Services sign-in

`GoogleSignInButton` (`src/components/google-sign-in-button.tsx`), rendered on `auth.tsx`, wraps Google's official Identity Services "Sign in with Google" button. Unlike the Google Maps integration, it loads Google's `<script src="https://accounts.google.com/gsi/client">` directly rather than an npm package — no new frontend dependency.

- **Gated behind `VITE_GOOGLE_CLIENT_ID`** (see `.env.example`), same fallback philosophy as `LocationPicker`: unset, the component renders `null` and `auth.tsx` hides the button + "or with email" divider entirely, leaving email/password as the only sign-in path. Must be the same Client ID as the backend's `GOOGLE_CLIENT_ID` (`infrastructure/variables.tf`'s `google_client_id` — not a secret, it's compiled into the frontend bundle either way).
- On credential (an ID token, not an access token), the button's callback calls `authApi.google(idToken)` → `POST /api/v1/auth/google`, which does all real verification server-side — the frontend never validates or trusts the token itself.

### Frontend: reCAPTCHA v3 on signup

`getRecaptchaToken()` (`src/lib/recaptcha.ts`), called from `auth.tsx`'s `handleSignUp` right before `authApi.signup`, gets an invisible reCAPTCHA v3 token scoped to the `"signup"` action and sends it as `recaptcha_token`. Like `GoogleSignInButton`, it loads Google's `<script src="https://www.google.com/recaptcha/api.js?render=...">` directly rather than an npm package.

- **Gated behind `VITE_RECAPTCHA_SITE_KEY`** (see `.env.example`) — unset, `getRecaptchaToken()` resolves to `undefined` immediately with no script ever loaded, and signup still works with no captcha check (the backend only enforces verification once `RECAPTCHA_SECRET_KEY` is also set — see "Backend: Rails API, JWT auth, no sessions" above). Both sides must be configured for the check to actually run; setting only one has no effect.
- Sign-in and sign-up are otherwise plain `<form onSubmit>`s (not just `<Button onClick>`s) so pressing Enter in a field submits, same as clicking the button.
- The sign-up form also validates a "confirm password" field client-side (`validateSignUp` in `auth.tsx`) before ever calling `authApi.signup` — there's no matching server-side confirmation param; the backend only ever sees the one `password` value.

### Frontend: TanStack Start file-based routing

- **Production build is a static SPA, not an SSR app**, despite this being TanStack Start. `vite.config.ts` is a plain Vite config (no `@lovable.dev/vite-tanstack-config` wrapper — removed 2026-08-19; everything that package added beyond assembling `tailwindcss`/`vite-tsconfig-paths`/`tanstackStart`/`viteReact` only activated inside Lovable's own hosted sandbox, which this app never runs in) that registers no `nitro()` plugin at all, so TanStack Start's own per-request SSR build (which would otherwise default to a `cloudflare-module` preset — a Cloudflare Workers SSR target, output to `.output/`) never gets wired up. `tanstackStart.spa.enabled` instead prerenders one HTML shell at build time (crawling from `/`) to `dist/client/index.html`; every route then hydrates and renders client-side from that same shell, same as a classic Vite SPA. This matches the actual deploy target (`infrastructure/frontend.tf` — S3 + CloudFront, which can only serve static files, not run a server) — `src/server.ts`'s Workers `fetch` handler is dead code as a result, unused unless a `nitro()` plugin is added back. Only `dist/client/` gets synced to S3 (`dist/server/` is just the build-time prerender driver); see `.github/workflows/deploy.yml` and `scripts/deploy.sh`.
- Routing follows `src/routes/README.md` conventions: every file in `src/routes/` is a route, `$id` for dynamic segments, `_layout.tsx` for layout routes, `__root.tsx` is the app shell. `routeTree.gen.ts` is generated — never hand-edit it.
- `src/routes/_authenticated/` is a layout route gating dashboard pages behind auth (`route.tsx` checks auth state before rendering children).
- All backend communication goes through `src/lib/api-client.ts`, a hand-written fetch wrapper (not React Query directly, though `@tanstack/react-query`'s `QueryClient` is wired into the router context). It reads `VITE_API_URL` (defaults to `http://localhost:3001` — note this differs from the Rails default port 3000, so set `VITE_API_URL=http://localhost:3000` or run Rails on 3001 locally) and stores the JWT in `localStorage` under `rally_token`. `src/lib/use-auth.tsx` wraps this in an `AuthProvider`/`useAuth()` context.
- This project started from a Lovable/Supabase scaffold; that origin is now fully cleaned up — there's no `src/integrations/` directory anymore, and `api-client.ts`'s own header comment ("replaces all Supabase queries") is the only trace left. Real app data and auth flow through the Rails API via `api-client.ts`/`use-auth.tsx` — don't reintroduce a Supabase path for new features.
- UI components in `src/components/ui/` are shadcn/ui primitives — prefer composing these over adding new UI libraries. These are treated as vendored/out-of-scope for app-specific work (e.g. i18n) the same way `src/components/ui/chart.tsx` already had pre-existing, unrelated TS errors before any of this session's work.
- `SiteHeader` (`src/components/site-header.tsx`) renders a "Welcome, {name}" avatar dropdown (Edit profile / Payment settings / Sign out) once logged in, replacing a plain sign-out button; `use-auth.tsx`'s `refresh()` is called after profile saves so the header updates immediately. The dropdown's "Payment settings" item deep-links to `profile.tsx`'s `#payment-settings` anchor.

### Frontend: i18n (English + Khmer)

The frontend is fully wired for translation via `i18next`/`react-i18next` — every user-facing string in `src/routes/` and `src/components/*.tsx` (excluding `src/components/ui/` shadcn primitives) goes through `t("namespace.key")`, not hardcoded literals.

- `src/lib/i18n.ts` initializes the i18next singleton and exports `SUPPORTED_LANGUAGES` (`en`, `km`), `setLanguage()`, and `applyStoredLanguage()`. **It always boots to English on both server and the client's first render** — the production build is one HTML shell prerendered once at build time (see "Frontend: TanStack Start file-based routing" above) and reused for every visitor, so it has no way to know any individual visitor's stored language, and applying one synchronously would cause a hydration mismatch against that shell anyway. The stored preference (`localStorage["rally_lang"]`) is only applied client-side, in a `useEffect` in `__root.tsx`, after mount.
- Locale files are `src/i18n/locales/en.json` (source of truth) and `src/i18n/locales/km.json` (Khmer), namespaced roughly one-per-route/component (`header`, `home`, `auth`, `eventDetail`, `dashboard`, `manageEvent`, `eventForm`, `profile`, `surveyBuilder`, etc.). Keep both files in lockstep — every key added to `en.json` needs a `km.json` counterpart, or the UI silently falls back to the English string when `km` is active.
- `LanguageSwitcher` (`src/components/language-switcher.tsx`) is the globe-icon control in `SiteHeader`; it calls `setLanguage()`, which updates `localStorage`, `i18n.changeLanguage()`, and `document.documentElement.lang`.
- Non-component code that needs translated strings (e.g. `src/lib/event-utils.ts`'s `formatPrice`/`formatDate`/`categoryLabel`) imports the `i18n` default export directly and calls `i18n.t(...)` / reads `i18n.language`, rather than needing the `useTranslation()` hook — this only works because these functions are called synchronously inside a component's render body, so they naturally re-run on re-render after a language change.
- Zod validation schemas (`auth.tsx`, `forgot-password.tsx`, etc.) intentionally carry no error message strings (e.g. `z.string().min(8)`, not `.min(8, "...")`) — the translated message is chosen at the `safeParse` call site based on which check failed, since zod's own message API isn't translation-aware.
- Route `head()` meta (page `<title>`, SEO `<meta description>`) is deliberately left in English — it's not run through `t()`.
- `EVENT_CATEGORIES` (a `{value, label}[]` constant) no longer exists in `event-utils.ts`; use `eventCategoryOptions()` (a function, so it re-evaluates per-render/per-language) or the bare `EVENT_CATEGORY_VALUES` string array instead.

### Frontend: Google Maps location picker

`LocationPicker` (`src/components/location-picker.tsx`), used on the create-event form (`events.new.tsx`), is a search-as-you-type Places Autocomplete input plus a draggable pin on an embedded map. It's built on `@googlemaps/js-api-loader`'s v2 functional API (`setOptions()` once, then `importLibrary("places" | "maps" | "marker")`), not the older `Loader` class.

- **Gated entirely behind `VITE_GOOGLE_MAPS_API_KEY`** (see `.env.example`). Without it, `LocationPicker` renders a plain text `<Input>` instead — no map, no autocomplete, `latitude`/`longitude` stay `null` — so event creation still works with zero Google Cloud setup. Don't assume the key is present when touching this component.
- The text input is deliberately **uncontrolled** (`defaultValue`, not `value`) once the map key is present — Google's `Autocomplete` widget writes directly into the input's DOM value when a suggestion is picked, which would fight a React-controlled value. The authoritative source for the selected address is the `place_changed` listener, not the input's `onChange` (which only tracks manual free-typing between selections).
- Uses the classic `google.maps.Marker` (via `importLibrary("marker")`), not `AdvancedMarkerElement` — the latter needs a Cloud Console "Map ID" to be configured, which is one more setup step this intentionally avoids.
- `tsconfig.json`'s `compilerOptions.types` explicitly includes `"google.maps"` (alongside `"vite/client"`) — without that, `@types/google.maps`'s global `google` namespace won't resolve even though the package is installed, since `types` being present at all restricts automatic global type inclusion to just what's listed.
- `googleMapsViewUrl()` in `event-utils.ts` builds a plain `https://www.google.com/maps?q=lat,lng` link for the "View on map" links on the event detail/manage pages — this needs no API key at all (it's just an outbound link, not an embed), so those pages work regardless of whether `VITE_GOOGLE_MAPS_API_KEY` is configured.

### Infrastructure

Terraform (`infrastructure/`) provisions: ECS (backend container), ECR, RDS-style database, S3+CloudFront (frontend static hosting), IAM, networking, secrets. `backend/config/deploy.yml` (Kamal) is unconfigured Rails-generated scaffolding (placeholder IP, local registry) — it is not the real deploy path and shouldn't be treated as one.

CD is `.github/workflows/deploy.yml`, triggered on push to `main`, gated by the same path-based change detection as CI (`dorny/paths-filter`, so a push only deploys the subproject(s) that actually changed):

- **`deploy-frontend`** — `npm run build`, then `aws s3 sync` to the frontend bucket and a CloudFront invalidation.
- **`deploy-backend`** — builds the `backend/Dockerfile` image for `linux/amd64` (Fargate), pushes it to ECR tagged `:${{ github.sha }}` and `:latest`, then `aws ecs update-service --force-new-deployment` and waits for the service to stabilize. This mirrors `scripts/deploy.sh --backend-only`, the manual/local equivalent (which additionally reads cluster/service/repo names from `terraform output` — CI can't do that since Terraform state isn't available there, so those are GitHub secrets instead). Migrations run automatically on container boot via `bin/docker-entrypoint` (`db:prepare`), not as a separate CD step. The ECS task definition always points at the `:latest` tag (`infrastructure/ecs.tf` → `var.rails_image_tag`, default `"latest"`) and Terraform ignores `container_definitions` after the first `apply`, so a deploy is just "push a new `:latest` and force ECS to re-pull it."

Both jobs read AWS credentials from the same `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` secrets. `deploy-backend` additionally needs `ECR_REPOSITORY` (repo name, e.g. `rally-production-api` — see `infrastructure/ecr.tf`'s `${local.prefix}-api`), `ECS_CLUSTER`, and `ECS_SERVICE` (both `${local.prefix}-cluster` / `${local.prefix}-api` by default — see `infrastructure/outputs.tf`) as repo secrets; the IAM credentials need ECR push + `ecs:UpdateService`/`ecs:DescribeServices` permissions on top of whatever the frontend job already requires.
