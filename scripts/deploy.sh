#!/usr/bin/env bash
# deploy.sh — builds the backend image, pushes to ECR, deploys ECS, then syncs the frontend.
#
# Usage:
#   ./scripts/deploy.sh            # uses git short SHA as image tag
#   ./scripts/deploy.sh v1.2.3     # uses custom tag
#   ./scripts/deploy.sh --frontend-only
#   ./scripts/deploy.sh --backend-only
#
# Prerequisites:
#   - AWS CLI configured (aws configure or IAM role)
#   - Docker daemon running
#   - Terraform applied (infrastructure/terraform.tfstate exists)
#   - npm installed for frontend builds

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}ℹ  $*${NC}"; }
success() { echo -e "${GREEN}✔  $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠  $*${NC}"; }
die()     { echo -e "${RED}✘  $*${NC}" >&2; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
DEPLOY_BACKEND=true
DEPLOY_FRONTEND=true
IMAGE_TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo "latest")}"

case "${1:-}" in
  --backend-only)  DEPLOY_FRONTEND=false; IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || echo "latest") ;;
  --frontend-only) DEPLOY_BACKEND=false;  IMAGE_TAG="" ;;
  --help|-h) echo "Usage: $0 [image-tag|--backend-only|--frontend-only]"; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$ROOT_DIR/infrastructure"

# ── Read Terraform outputs ────────────────────────────────────────────────────
info "Reading Terraform outputs..."
cd "$TF_DIR"

tf_output() { terraform output -raw "$1" 2>/dev/null || die "Terraform output '$1' not found. Run: terraform apply"; }

ECR_URL=$(tf_output ecr_repository_url)
ECS_CLUSTER=$(tf_output ecs_cluster_name)
ECS_SERVICE=$(tf_output ecs_service_name)
FRONTEND_BUCKET=$(tf_output frontend_bucket_name)
CLOUDFRONT_ID=$(tf_output cloudfront_distribution_id)
API_URL=$(tf_output api_url)
AWS_REGION=$(terraform output -raw alb_dns_name 2>/dev/null | grep -o 'us-[a-z]*-[0-9]' || echo "${AWS_DEFAULT_REGION:-us-east-1}")

# Also read region from provider config
AWS_REGION=$(terraform show -json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('values',{}).get('root_module',{}).get('resources',[{}])[0].get('provider_name','aws.us_east_1').split('.')[-1])" 2>/dev/null || echo "us-east-1")

# Fall back to reading from variables
if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
  AWS_REGION=$(grep -E '^aws_region' "$TF_DIR/terraform.tfvars" | awk -F'"' '{print $2}' || echo "us-east-1")
fi
AWS_REGION="${AWS_REGION:-us-east-1}"

cd "$ROOT_DIR"

echo ""
info "Deployment summary"
echo "  Region:    $AWS_REGION"
echo "  Image tag: ${IMAGE_TAG:-n/a}"
echo "  Cluster:   $ECS_CLUSTER"
echo "  Service:   $ECS_SERVICE"
echo ""

# ── Backend ───────────────────────────────────────────────────────────────────

if $DEPLOY_BACKEND; then
  info "Logging into ECR..."
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_URL"

  info "Building backend image ($IMAGE_TAG)..."
  docker build \
    --platform linux/amd64 \
    -t "$ECR_URL:$IMAGE_TAG" \
    -t "$ECR_URL:latest" \
    "$ROOT_DIR/backend"

  info "Pushing images to ECR..."
  docker push "$ECR_URL:$IMAGE_TAG"
  docker push "$ECR_URL:latest"
  success "Image pushed: $ECR_URL:$IMAGE_TAG"

  info "Triggering ECS rolling deploy..."
  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --force-new-deployment \
    --region "$AWS_REGION" \
    --output json > /dev/null

  info "Waiting for ECS service to stabilise (this can take 2–5 minutes)..."
  aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER" \
    --services "$ECS_SERVICE" \
    --region "$AWS_REGION"

  success "Backend deployed ✔"
fi

# ── Frontend ──────────────────────────────────────────────────────────────────

if $DEPLOY_FRONTEND; then
  FRONTEND_DIR="$ROOT_DIR/frontend"
  [[ -d "$FRONTEND_DIR" ]] || die "frontend/ directory not found at $FRONTEND_DIR"

  info "Building frontend (VITE_API_URL=$API_URL)..."
  cd "$FRONTEND_DIR"
  VITE_API_URL="$API_URL" npm run build

  info "Syncing frontend assets to S3..."
  # Long-lived cache for hashed assets; no-cache for index.html
  aws s3 sync dist/ "s3://$FRONTEND_BUCKET" \
    --delete \
    --cache-control "public,max-age=31536000,immutable" \
    --exclude "index.html"

  aws s3 cp dist/index.html "s3://$FRONTEND_BUCKET/index.html" \
    --cache-control "no-cache,no-store,must-revalidate" \
    --content-type "text/html"

  info "Invalidating CloudFront cache..."
  INVALIDATION_ID=$(aws cloudfront create-invalidation \
    --distribution-id "$CLOUDFRONT_ID" \
    --paths "/*" \
    --query 'Invalidation.Id' \
    --output text)
  success "Cache invalidation started: $INVALIDATION_ID"

  cd "$ROOT_DIR"
  success "Frontend deployed ✔"
fi

echo ""
success "🎉 Deployment complete!"
if $DEPLOY_FRONTEND; then
  echo "   Frontend: $(cd $TF_DIR && terraform output -raw frontend_url 2>/dev/null || echo 'see Terraform outputs')"
fi
if $DEPLOY_BACKEND; then
  echo "   API:      $API_URL"
fi
