# Rally

Rally is an event registration platform for races, rides, and community
gatherings — running, cycling, swimming, triathlon, hiking, and more.
Organizers create an event, open registrations under a pricing plan, and
manage the whole day (participants, payments, branding, surveys) from a
dashboard. Participants browse events, register (with optional sub-types and
a custom survey), and pay instantly via ABA KHQR.

The frontend ships in English and Khmer.

## Stack

| | |
|---|---|
| Backend | Rails 8.1 (Ruby 4.0.1), API-only, PostgreSQL, JWT auth |
| Frontend | TanStack Start (React 19), file-based routing, Vite, Tailwind v4, shadcn/ui |
| Payments | ABA PayWay (KHQR) |
| Infrastructure | Terraform on AWS — ECS (Fargate), RDS, S3 + CloudFront, Secrets Manager |
| CI/CD | GitHub Actions (`.github/workflows/ci.yml`, `deploy.yml`) |

## Repo layout

```
backend/          Rails API — app/, config/, spec/ (RSpec)
frontend/          TanStack Start app — src/routes/, src/components/, src/i18n/
infrastructure/     Terraform for the AWS deployment
scripts/deploy.sh   Manual/local deploy script (build → ECR → ECS, S3 → CloudFront)
```

Backend and frontend deploy independently — CI and CD only run a
subproject's jobs when files under that subproject changed.

## Getting started

### Prerequisites

- Ruby 4.0.1 (see `backend/.ruby-version`) and PostgreSQL
- Node.js 24+ and `bun` (or `npm`)

### Backend

```bash
cd backend
bin/setup                          # installs gems, prepares the db
bin/rails db:create db:migrate db:seed
bin/rails server -p 3000           # API on http://localhost:3000
```

The backend has sensible defaults for local dev (Postgres on `localhost`,
sandbox PayWay base URL) but reads secrets from `ENV`, not a `.env` file —
export them in your shell or via direnv. `JWT_SECRET` is the only one you
strictly need for a stable dev session; see
[ABA_PAYWAY_SETUP.md](./ABA_PAYWAY_SETUP.md) for `ABA_PAYWAY_MERCHANT_ID` /
`ABA_PAYWAY_API_KEY` (needed to exercise the payment flow locally) and
`MAILER_FROM_EMAIL` if you want outgoing mail (SES) configured.

### Frontend

```bash
cd frontend
bun install                        # or npm install
cp .env.example .env.local         # VITE_API_URL — see note below
bun run dev                        # http://localhost:5173
```

`VITE_API_URL` defaults to `http://localhost:3001`, which differs from the
Rails default port (3000) — either set `VITE_API_URL=http://localhost:3000`
in `.env.local` or run Rails with `-p 3001`.

### Tests & linting

```bash
# backend
cd backend
bundle exec rspec                  # full suite
bin/rubocop                        # lint (Omakase Rails style)
bin/brakeman                       # security scan

# frontend
cd frontend
bun run lint                       # eslint
bun run format                     # prettier --write .
```

## Deployment

Terraform in `infrastructure/` provisions the AWS resources (ECS cluster,
ECR, RDS, S3 + CloudFront, IAM, Secrets Manager). Once applied, deploys are
automatic: pushing to `main` triggers `.github/workflows/deploy.yml`, which
builds and pushes the backend image to ECR and rolls it out to ECS, and
syncs the frontend build to S3 with a CloudFront invalidation — each only
for the subproject that actually changed.

For a manual/local deploy (or to deploy both at once), see
`scripts/deploy.sh`:

```bash
./scripts/deploy.sh                # deploy both
./scripts/deploy.sh --backend-only
./scripts/deploy.sh --frontend-only
```

`backend/config/deploy.yml` (Kamal) is unused Rails-generated scaffolding —
ECS is the real deploy target, not Kamal.

## More docs

- [`CLAUDE.md`](./CLAUDE.md) — architecture notes: auth, domain model,
  payments (ABA PayWay), i18n, and CI/CD internals
- [`ABA_PAYWAY_SETUP.md`](./ABA_PAYWAY_SETUP.md) — one-time account setup for
  KHQR payments and transactional email
