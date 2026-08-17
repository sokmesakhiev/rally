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
cp .env.example .env               # optional — see below
bin/rails db:create db:migrate db:seed
bin/rails server -p 3000           # API on http://localhost:3000
```

The backend has sensible defaults for local dev (Postgres on `localhost`,
sandbox PayWay base URL) — nothing in `.env.example` is required to boot.
`.env` (gitignored) is loaded automatically in development/test via the
`dotenv-rails` gem; production never loads it and gets its config exclusively
from real ENV vars injected by ECS. `JWT_SECRET` is the only one worth
setting for a stable dev session (see the comment in `.env.example` for why);
see [ABA_PAYWAY_SETUP.md](./ABA_PAYWAY_SETUP.md) for `ABA_PAYWAY_MERCHANT_ID`
/ `ABA_PAYWAY_API_KEY` (needed to exercise the payment flow locally) and
`MAILER_FROM_EMAIL` if you want outgoing mail (SES) configured. If you'd
rather not add a gem dependency, exporting the same vars via your shell or
[direnv](https://direnv.net) works identically — `dotenv-rails` is just the
lower-friction default.

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

### Using a domain hosted outside Route 53

`api_domain`/`frontend_domain` don't have to live in Route 53 — leave
`route53_zone_id` empty in `terraform.tfvars` and Terraform still creates the
ACM certificates, it just can't create the DNS records itself. You add those
by hand at whatever host you use (Cloudflare, Namecheap, etc.):

1. `terraform apply`. **This first apply will likely error out on the
   CloudFront distribution and/or the ALB HTTPS listener specifically** —
   both need an already-*Issued* ACM certificate, and a brand-new one is
   always `PENDING_VALIDATION` until you complete step 2 below. That's
   expected, not a sign anything is broken: the certificate resources
   themselves still get created successfully (Terraform records them in
   state) even though the apply as a whole exits non-zero.
2. Read the `api_cert_validation_record` and `frontend_cert_validation_records`
   outputs (`terraform output api_cert_validation_record` /
   `terraform output frontend_cert_validation_records`) and add each as a
   CNAME at your DNS host. In Cloudflare, add them as **DNS only** (grey
   cloud, not proxied) — a proxied CNAME breaks ACM's validation crawler.
3. Wait for both certificates to show "Issued" in the ACM console (usually a
   few minutes) — the frontend/CloudFront cert lives in **us-east-1**
   regardless of your app's region; the API/ALB cert lives in your app's
   own region (`aws_region` in `terraform.tfvars`).
4. Run `terraform apply` again. This time CloudFront and the ALB listener
   pick up the now-Issued certificates and finish deploying — no code
   changes needed, just re-running against the same config.
5. Point `api_domain` at the `alb_dns_name` output via CNAME, and
   `frontend_domain` + `www.<frontend_domain>` at the `cloudfront_domain`
   output via CNAME.
6. If you proxy these final records through Cloudflare (orange cloud), set
   Cloudflare's SSL/TLS mode to **Full** or **Full (strict)** — Cloudflare
   terminates TLS to visitors either way, but "Flexible" mode would then
   speak plain HTTP to the ALB, which redirects to HTTPS and can loop.

The `next_steps` Terraform output walks through this same sequence after
every `apply`.

## More docs

- [`CLAUDE.md`](./CLAUDE.md) — architecture notes: auth, domain model,
  payments (ABA PayWay), i18n, and CI/CD internals
- [`ABA_PAYWAY_SETUP.md`](./ABA_PAYWAY_SETUP.md) — one-time account setup for
  KHQR payments and transactional email
