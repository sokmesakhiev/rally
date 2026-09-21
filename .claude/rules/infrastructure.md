# Infrastructure and deployment

Loaded on demand — see the trigger table in CLAUDE.md. Everything here is
hard-won detail about *why* the code is shaped the way it is; it was moved out
of CLAUDE.md verbatim, not rewritten.

### Infrastructure

Terraform (`infrastructure/`) provisions: ECS (backend container), ECR, RDS-style database, S3+CloudFront (frontend static hosting), IAM, networking, secrets. `backend/config/deploy.yml` (Kamal) is unconfigured Rails-generated scaffolding (placeholder IP, local registry) — it is not the real deploy path and shouldn't be treated as one.

CD is `.github/workflows/deploy.yml`, triggered on push to `main`, gated by the same path-based change detection as CI (`dorny/paths-filter`, so a push only deploys the subproject(s) that actually changed):

- **`deploy-frontend`** — `npm run build`, then `aws s3 sync` to the frontend bucket and a CloudFront invalidation.
- **`deploy-backend`** — builds the `backend/Dockerfile` image for `linux/amd64` (Fargate), pushes it to ECR tagged `:${{ github.sha }}` and `:latest`, then `aws ecs update-service --force-new-deployment` on **both** backend services — the API first, waited to stable, then the Solid Queue worker (see "background jobs" above for why that order matters and why a skipped worker deploy is the quiet failure to watch for). This mirrors `scripts/deploy.sh --backend-only`, the manual/local equivalent (which additionally reads cluster/service/repo names from `terraform output` — CI can't do that since Terraform state isn't available there, so those are GitHub secrets instead). Migrations run automatically on container boot via `bin/docker-entrypoint` (`db:prepare`), on the web task only, not as a separate CD step. Both task definitions always point at the `:latest` tag (`infrastructure/ecs.tf` → `var.rails_image_tag`, default `"latest"`), so a deploy is just "push a new `:latest` and force ECS to re-pull it" — Terraform is what changes anything else about a task definition.

Both jobs read AWS credentials from the same `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` secrets. `deploy-backend` additionally needs `ECR_REPOSITORY` (repo name, e.g. `rally-production-api` — see `infrastructure/ecr.tf`'s `${local.prefix}-api`), `ECS_CLUSTER`, `ECS_SERVICE`, and `ECS_WORKER_SERVICE` (`${local.prefix}-cluster` / `${local.prefix}-api` / `${local.prefix}-worker` by default — see `infrastructure/outputs.tf`) as repo secrets; the IAM credentials need ECR push + `ecs:UpdateService`/`ecs:DescribeServices` permissions on top of whatever the frontend job already requires.
