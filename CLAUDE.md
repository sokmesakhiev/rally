# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

**This file is loaded on every turn, so it stays small.** The detail — why each
subsystem is shaped the way it is — lives in `.claude/rules/`, loaded only when
the work touches it. Use the trigger table below.

> **Do not convert the rule list into `@` imports.** Claude Code inlines
> `@path` references into this file, which would put all ~14,000 words back
> into every turn and undo the point of the split. The paths below are
> instructions to *go and read*, not imports.

## Project overview

"Rally" is an event registration platform (running/cycling/swimming/triathlon)
with three parts:

- `backend/` — Rails 8.1 API-only app (Ruby 4.0.7, PostgreSQL, RSpec)
- `frontend/` — TanStack Start (React 19, file-based routing, Vite, Tailwind v4, shadcn/ui)
- `infrastructure/` — Terraform for AWS (ECS backend, S3+CloudFront frontend)

Backend and frontend deploy independently; CI (`.github/workflows/ci.yml`) only
runs a subproject's jobs when files under it changed.

## Commands

### Backend (from `backend/`)

```
bin/setup                                      # install gems, prepare db
bin/rails server -p 3000                       # run the API
bin/rails db:create db:migrate db:seed

bundle exec rspec                              # whole suite
bundle exec rspec spec/models/event_spec.rb    # one file
bundle exec rspec spec/models/event_spec.rb:42 # one example

bin/rubocop          # lint (Omakase Rails style); -A to autocorrect
bin/brakeman         # static security scan
bin/bundler-audit    # dependency vulnerabilities
```

RSpec is the real suite (`spec/factories`, `spec/requests`, `spec/models`).
`backend/test/` is unused Minitest scaffolding — don't add tests there.

### Frontend (from `frontend/`)

```
npm ci               # NOT bun — bun.lock is stale to the point of being unusable
npm run dev          # vite, port 8080
npm run build        # → dist/client/, deployed to S3
npm run test         # vitest
npm run test:coverage  # what CI runs
npm run lint         # eslint — fails on a pre-existing backlog; not in CI
npm run format       # prettier --write .
```

`bun.lock` contains neither `vitest` nor `i18next`, so it predates both the test
suite and i18n. Dependabot only updates `package-lock.json` and CI uses
`npm ci`. ESLint is **not** in `ci.yml`.

## Which rules to read

Read the file before writing code in the matching area. One file is usually
enough; they're written to stand alone.

| Working on | Read |
|---|---|
| Any controller, request schema, auth, `User`/`Event`/`Registration` | `.claude/rules/backend-conventions.md` |
| Sign-up limits, closing registration, waitlist, participant list | `.claude/rules/registration-and-capacity.md` |
| Event visibility, unlisted events, reporting, suspension, the admin queue | `.claude/rules/events-and-moderation.md` |
| Anything touching money, PayWay, KHQR, plans | `.claude/rules/payments.md` |
| Jobs, `recurring.yml`, Solid Queue/Cache, CloudWatch alarms | `.claude/rules/jobs-and-monitoring.md` |
| Certificate templates, PDF rendering, bib numbers | `.claude/rules/certificates.md` |
| ActionCable, channels, cable tickets | `.claude/rules/realtime.md` |
| `Conversation`/`Message`, support chat either side, retention | `.claude/rules/support-chat.md` |
| `ImpersonationSession`, "view as", anything in `ApplicationController`'s auth | `.claude/rules/impersonation.md` |
| Notification kinds, the bell, push, notifier services | `.claude/rules/notifications.md` |
| Routing, `api-client.ts`, `use-auth`, i18n | `.claude/rules/frontend-conventions.md` |
| Tab bars, banners, Google Maps/sign-in, reCAPTCHA | `.claude/rules/frontend-ui.md` |
| Terraform, ECS, deploy workflows | `.claude/rules/infrastructure.md` |

Touching auth, payments or moderation? Read the file **first**, not after the
first failing test. Those three are where a wrong assumption is expensive.

## House invariants

These apply everywhere, which is why they're here rather than in a rule file.
Each one has drawn blood at least once. Each line is a trigger — go read the
detail when it fires.

**Data and schema**

- Money is always `*_cents` integers. Never floats.
- A **partial unique index needs a matching `conditions:`** on the model's
  uniqueness validation, *and* callers must rescue both `RecordInvalid` and
  `RecordNotUnique` — which one fires depends on how the race lands, and
  handling one leaves a 500 nobody can reproduce.
- Predicates like "closed", "live", "expired" are **evaluated, never stored as
  a flag**. A boolean needs a cron job to maintain and has a window where it's
  wrong.
- `User#discard!` is a soft delete written with `update!`, so **no
  `dependent: :destroy` on `User` ever fires**. Adding one means deciding
  explicitly whether `#discard!` should do it too.
- Migration timestamps must **not be in the future** — Rails 8.1 refuses them,
  and hand-dating a file `YYYYMMDD010000` breaks the moment it lands past
  midnight. Use `bin/rails generate migration`.

**Rails**

- Request schemas: `.maybe`, not `.value`, for anything the frontend can send
  as null. A `.maybe` over a NOT NULL-with-default column is a **500, not a
  422** — run params through `ApplicationRecord.reject_nils_for_defaulted_columns`.
- Controllers hand-build JSON hashes; there are no serializers. Authorization
  is manual per-controller; there is no Pundit.
- `%w[]` has **no comment syntax** — a `#` line between the brackets becomes
  array elements.

**Frontend**

- `routeTree.gen.ts` is generated. Never hand-edit it.
- Every key added to `en.json` needs a `km.json` counterpart or the UI silently
  falls back to English. Khmer omits `_one` plural forms.
- `src/components/ui/` is vendored shadcn — override at the call site rather
  than editing it.
- Never use `localStorage`/`sessionStorage` in artifacts rendered in
  conversation (the real app uses them normally).

**Working agreement**

- **Executable guards beat prose rules.** A rule someone must remember gets
  violated; a spec that fails at the moment of violation doesn't. When a rule
  has to hold across files, write the test — see the PayWay serializer guard in
  `spec/requests/impersonation_spec.rb`.
- **Comments that describe intent are not evidence the wiring exists.**
  `GenerateCertificatesJob` documented a schedule it wasn't on and had never
  run in production; its spec passed throughout because it only covered the
  filters that were there.
- Claude has **no git push access**. Hand over exact commands instead.

## What Claude cannot verify in this sandbox

Worth stating plainly, because it shapes how much a "looks right" claim is
worth:

- **RSpec cannot run.** The sandbox has Ruby 3.0 against this project's 4.0.7,
  and `bundle install` isn't available. `ruby -c` (syntax only) is the ceiling.
  RuboCop and Brakeman are equally unavailable.
- **Vitest cannot run.** `node_modules/@rolldown/` ships only
  `binding-darwin-arm64`.
- `npx tsc --noEmit` and `npx prettier` **do** work. There is a standing
  baseline of pre-existing TS errors (`src/components/ui/chart.tsx`,
  `vite.config.ts`, and others) — compare counts against the baseline rather
  than expecting zero.
- The sandbox clock can differ from the host's by a day, so anything
  time-sensitive (migration timestamps) needs checking on your machine.

So: specs Claude writes are unrun until you run them. Treat a green claim about
Ruby or Vitest as "syntax parses", nothing more.
