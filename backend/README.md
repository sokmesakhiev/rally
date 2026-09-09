# Rally — backend

The Rails 8.1 API behind Rally, an event registration platform for running,
cycling, swimming and triathlon events in Cambodia.

API-only: it serves JSON under `/api/v1` and renders no views. The React
frontend lives in [`../frontend`](../frontend) and deploys independently.

**Architecture, domain model and the reasoning behind the design live in
[`../CLAUDE.md`](../CLAUDE.md).** This file is about getting the thing running
and working on it day to day. That split is deliberate — two documents
describing the same architecture drift apart, and the one nobody edits becomes
the misleading one.

## Requirements

| | |
|---|---|
| Ruby | `4.0.1` (see `.ruby-version`) |
| PostgreSQL | 15+ |
| libvips | Active Storage's image processor. `brew install vips`, or `apt-get install libvips` |

`ruby-vips` in the Gemfile is bindings only — the native library isn't bundled
with the gem, so image uploads fail confusingly without it.

## Setup

```sh
bin/setup                # bundle install, db:prepare, then starts the server
bin/setup --skip-server  # same, without starting anything
```

Then copy the environment template:

```sh
cp .env.example .env
```

**Nothing in `.env` is required to boot.** Every variable either has a working
default or gates an optional feature off entirely when unset — you can run the
app, create events and register for them with an empty file. `.env.example`
documents what each one turns on; read it there rather than here, so there's
one description of each variable rather than two.

The short version of what you'll miss without credentials: no payments (ABA
PayWay), no "Sign in with Google", no reCAPTCHA on signup. All three degrade
cleanly rather than erroring.

## Running it

```sh
bin/rails server -p 3000
```

### A note on ports

Three different defaults are in play, and they don't agree:

| Thing | Port |
|---|---|
| Rails (`bin/rails server`) | 3000 |
| Vite dev server (`frontend/vite.config.ts`) | 8080 |
| What the frontend expects the API on (`VITE_API_URL` default) | **3001** |

So a default `bin/rails server` and a default `bun run dev` will not talk to
each other. Pick one:

```sh
bin/rails server -p 3001                      # match the frontend's default
# ...or set VITE_API_URL=http://localhost:3000 in frontend/.env
```

Also note `.env.example` ships `FRONTEND_URL=http://localhost:5173` — Vite's
generic default, not this project's. If you rely on `FRONTEND_URL` for email
links or CORS locally, set it to `http://localhost:8080`.

## Database

```sh
bin/rails db:create db:migrate db:seed
bin/rails db:reset                  # drop, recreate, reload schema, reseed
```

`db/schema.rb` is generated. Never hand-edit it — change a migration and
re-run.

Migration timestamps must be in the past and later than the current schema
version, or Rails refuses to load them. If you're writing a migration on a
branch that's been open a while, check `db/schema.rb`'s `define(version:)`
line first.

## Tests

RSpec is the real suite. Factories are in `spec/factories`, request specs in
`spec/requests`, model specs in `spec/models`.

```sh
bundle exec rspec                                # everything
bundle exec rspec spec/models/event_spec.rb      # one file
bundle exec rspec spec/models/event_spec.rb:42   # one example, by line
```

Two traps worth knowing:

- **`backend/test/` is unused** default Rails/Minitest scaffolding. Don't add
  tests there; nothing runs them in CI.
- **`bin/ci` does not run RSpec.** `config/ci.rb` runs `bin/rails test`, which
  is the empty Minitest suite above, so `bin/ci` can pass green having executed
  no real tests. Use `bundle exec rspec` directly, and treat `bin/ci` as a lint
  and security runner only. GitHub Actions (`.github/workflows/ci.yml`) runs
  RSpec correctly.

## Linting and security

```sh
bin/rubocop            # Omakase Rails style
bin/rubocop -A         # autocorrect
bin/brakeman           # static security analysis
bin/bundler-audit      # known CVEs in gems
```

Brakeman findings that are deliberate get suppressed in `config/brakeman.ignore`
— add them with `bin/brakeman -I` rather than editing the file, since the
entries are fingerprints.

CI runs `bin/rubocop -f github` and `bin/brakeman --no-pager` on every PR that
touches `backend/`.

## Background jobs and cache

Solid Queue and Solid Cache run in **production only** — the gems sit in the
Gemfile's `group :production`. Development caches to `:memory_store`, test to
`:null_store` with the `:test` job adapter. Nothing extra is needed to run
specs or a local server, and there's no queue database to set up.

In production the Solid Queue supervisor runs *inside* the Puma process
(`SOLID_QUEUE_IN_PUMA`, set in `infrastructure/ecs.tf`) rather than as a
separate worker service. See CLAUDE.md for when that tradeoff should be
revisited.

## Deployment

Deploys run from `.github/workflows/deploy.yml` on push to `main`, gated by
path filters so a frontend-only change doesn't redeploy the API. The image is
built for `linux/amd64`, pushed to ECR, and ECS is forced to re-pull.
Migrations run automatically on container boot via `bin/docker-entrypoint`
(`db:prepare`), not as a separate step.

`scripts/deploy.sh --backend-only` is the manual equivalent.

`config/deploy.yml` (Kamal) is unconfigured `rails new` scaffolding with a
placeholder IP. It is **not** the deploy path — ignore it.

## Where things are

```
app/controllers/api/v1/   All endpoints. Everything is namespaced /api/v1.
app/models/               Domain models, plus value objects like RefundPolicy.
app/services/             Multi-step operations (payments, refunds, waitlists).
app/request_schemas/      dry-validation schemas, validated before the model.
config/payway.yml         ABA PayWay credentials per environment.
spec/                     RSpec. The real test suite.
```

Auth is stateless JWT (`lib/json_web_token.rb`), not Devise or Rails sessions.
Authorization is the `EventAuthorization` concern's capability matrix, applied
per-action — there is no Pundit or CanCanCan. Controllers hand-build their JSON
response hashes rather than using serializers; follow that pattern when adding
endpoints.

See [`../CLAUDE.md`](../CLAUDE.md) for why, and for the parts that are easy to
get wrong.
