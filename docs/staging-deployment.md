# Staging deployment

One EC2 box, deployed with Kamal, on every push to `staging`. Production is
unchanged: it stays on ECS Fargate, rolled by `.github/workflows/deploy.yml`.

| | Production | Staging |
|---|---|---|
| Backend compute | ECS Fargate, 2 services (api + worker) | 1 EC2 box, Kamal, 2 roles (`web` + `job`) |
| Rolled by | `deploy.yml` → `ecs update-service` | `deploy-staging.yml` → `kamal deploy -d staging` |
| Database | RDS | `postgres:17` Kamal accessory on the box |
| Frontend | S3 + CloudFront | S3 + CloudFront (separate bucket/distribution) |
| Uploads | S3, via ECS task role | S3, via EC2 instance profile |
| Image registry | `rally-production-api` | **`rally-staging-api`** — see below |
| Terraform state | `…/production/terraform.tfstate` | `…/staging/terraform.tfstate` |
| Approval | required reviewers on the `production` environment | none; merging is the approval |

## Four things that will bite if you skip them

**The ECR repository must not be shared with production.** Kamal pushes a
`latest` tag alongside the versioned one. Production's ECS task definitions
point at `:latest` by design (`var.rails_image_tag`), and a production deploy
is just "force ECS to re-pull it". One shared repository would therefore mean
every staging deploy silently re-points production at a staging image, and the
next production deploy — or any task replacement, or a scale-up — rolls it out.
A production outage caused by merging to `staging`, with nothing in either
pipeline looking wrong. `infrastructure/staging/storage.tf` creates the separate
repository; confirm the tags Kamal pushes with
`kamal build push -d staging --verbose` before trusting this paragraph.

**DNS for `api_domain` must resolve to the box before the first deploy.**
`config/environments/production.rb` hardcodes `force_ssl = true`, staging runs
as `RAILS_ENV=production`, so there has to be a certificate — and kamal-proxy
gets it from Let's Encrypt over HTTP-01, which means the CA has to reach the
box by name. A first deploy against unpropagated DNS fails at issuance, after
the image is built and pushed.

**Staging runs as `RAILS_ENV=production`, on purpose.** Three things are wired
to that literal value rather than to "is this the live site": `solid_queue`,
`solid_cache` and `solid_cable` are in the Gemfile's `:production` group;
`config/database.yml` has only a `production:` block, whose cache/queue/cable
roles substitute `backend_production_*` into `DATABASE_URL`; and
`config/storage.yml`'s S3 service is selected by `production.rb`. Any other
value boots with no job queue, no cache backend and no ActionCable pub/sub. The
visible cost is that the auxiliary databases on the staging box are named
`backend_production_cache`, `_queue` and `_cable`. Leave them.

**`proxy.app_port` is 3001, not 80.** `backend/Dockerfile` bakes
`HTTP_PORT=3001`, so Thruster listens there. Kamal's proxy defaults to 80;
getting this wrong presents as the proxy never finding a healthy container
while the application logs look perfectly fine.

## Standing it up

```bash
# 1. State bucket (reuses production's, different key)
cd infrastructure/staging
cp backend.hcl.example backend.hcl        # fill in the bucket
cp terraform.tfvars.example terraform.tfvars

# A dedicated deploy key. The private half becomes STAGING_SSH_PRIVATE_KEY.
ssh-keygen -t ed25519 -C "rally-staging-deploy" -f ~/.ssh/rally_staging

terraform init -backend-config=backend.hcl
terraform apply

# 2. DNS — do this now, and wait for it to resolve
terraform output dns_records_to_create
terraform output frontend_cert_validation_records
dig +short api.staging.example.com        # must return the Elastic IP

# 3. Prepare the box and deploy once by hand, so the first CD run is a
#    deploy rather than a provisioning run. `kamal setup` installs Docker,
#    starts the proxy, and boots the Postgres accessory.
cd ../../backend
export KAMAL_HOST=$(terraform -chdir=../infrastructure/staging output -raw app_public_ip)
export KAMAL_IMAGE=$(terraform -chdir=../infrastructure/staging output -raw ecr_repository_name)
export KAMAL_REGISTRY_SERVER=$(terraform -chdir=../infrastructure/staging output -raw ecr_registry)
export KAMAL_PROXY_HOST=api.staging.example.com
export KAMAL_REGISTRY_PASSWORD=$(aws ecr get-login-password --region ap-southeast-1)
# …plus the app env and secrets listed below
bin/kamal setup -d staging

# 4. Seed it, if you want something to click on
bin/kamal app exec -d staging "bin/rails db:seed"
```

Then push to `staging` and the workflow takes over.

## Repo variables and secrets

All named `STAGING_*`. **That prefix is a safety property, not a convention**:
GitHub Environments inherit repo-level secrets for any name the environment
doesn't define, so a job reading `secrets.S3_BUCKET` under an incompletely
configured `staging` environment would silently resolve to production's bucket
— and the frontend job runs `aws s3 sync --delete`. A distinct name resolves to
empty and the deploy fails instead.

Variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Where from |
|---|---|
| `STAGING_AWS_REGION` | e.g. `ap-southeast-1` |
| `STAGING_HOST` | `output app_public_ip` |
| `STAGING_API_HOST` | the `api_domain` value, hostname only |
| `STAGING_API_URL` | `output api_url` |
| `STAGING_ECR_IMAGE` | `output ecr_repository_name` — the **name**, e.g. `rally-staging-api` |
| `STAGING_ECR_REGISTRY` | `output ecr_registry` — the host only |
| `STAGING_UPLOADS_BUCKET` | `output uploads_bucket` |
| `STAGING_FRONTEND_BUCKET` | `output frontend_bucket` |
| `STAGING_FRONTEND_URL` | `output frontend_url` |
| `STAGING_CLOUDFRONT_DIST_ID` | `output cloudfront_distribution_id` |
| `STAGING_MAILER_FROM_EMAIL` | a verified SES identity |
| `STAGING_ABA_PAYWAY_BASE_URL` | the **sandbox** host |
| `STAGING_GOOGLE_CLIENT_ID`, `STAGING_VITE_GOOGLE_CLIENT_ID` | must be the same value |
| `STAGING_VITE_SENTRY_DSN` | optional |

Secrets:

| Secret | Notes |
|---|---|
| `STAGING_AWS_ACCESS_KEY_ID` / `STAGING_AWS_SECRET_ACCESS_KEY` | ECR push, S3 sync, CloudFront invalidation |
| `STAGING_SSH_PRIVATE_KEY` | the key pair from step 1 |
| `STAGING_RAILS_MASTER_KEY` | the same `config/master.key` as production — it decrypts credentials in the repo, so it cannot differ |
| `STAGING_JWT_SECRET` | **must differ from production's.** Tokens last 30 days; a staging token must not authenticate against production |
| `STAGING_POSTGRES_PASSWORD` | the accessory's password; `DATABASE_URL` is assembled from it in `.kamal/secrets` |
| `STAGING_ABA_PAYWAY_MERCHANT_ID` / `_API_KEY` | sandbox credentials |
| `STAGING_RECAPTCHA_SECRET_KEY`, `STAGING_SENTRY_DSN` | may be empty, but must exist — Kamal requires every `env.secret` name to resolve |
| `STAGING_VITE_GOOGLE_MAPS_API_KEY`, `STAGING_VITE_RECAPTCHA_SITE_KEY` | optional; the features gate themselves off |

## Running it

```bash
bin/kamal deploy   -d staging         # what CI runs
bin/kamal rollback -d staging         # previous version, still on the box
bin/kamal app logs -d staging -f
bin/kamal console  -d staging
bin/kamal reset-db -d staging         # drop, migrate, seed — staging is disposable
```

`workflow_dispatch` with `force_all` re-deploys both subprojects when the
paths filter's answer is wrong — a rotated secret or a rebuilt box is not a
file change.

## What this does not give you

- **No backups.** The database is a Docker volume on one instance. A
  `docker volume rm`, or replacing the instance, loses it. That is the accepted
  cost of not running a second RDS instance; `reset-db` is the recovery story.
- **No monitoring.** `infrastructure/monitoring.tf`'s worker-liveness alarm is
  production-only, so a staging worker that boots and then fails every job
  looks identical to a healthy one. The signal it watches
  (`WorkerLivenessJob`'s log line) is in the container logs if you go looking.
- **No approval gate**, deliberately.
- **CI and the deploy are not gated on each other.** Both start on the same
  push, so a red suite does not stop the deploy.
- **SSH is open to `0.0.0.0/0`** by default, because GitHub-hosted runners have
  no stable egress range. Narrowing it means a self-hosted runner, or a step
  that opens the security group for the length of the deploy.
- **The `Terraform` job in `ci.yml` does not validate this directory.** It is
  triggered by changes under `infrastructure/**` but runs with
  `working-directory: infrastructure`, so `infrastructure/staging/` is never
  planned — the job goes green having checked the wrong thing. Worth a matrix
  over both directories.
