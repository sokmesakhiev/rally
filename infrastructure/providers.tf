terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # ── Remote state ──────────────────────────────────────────────────────────
  # Create the S3 bucket BEFORE running terraform init:
  #
  #   aws s3api create-bucket \
  #     --bucket <YOUR_BUCKET_NAME> \
  #     --region ap-southeast-1
  #
  #   aws s3api put-bucket-versioning \
  #     --bucket <YOUR_BUCKET_NAME> \
  #     --versioning-configuration Status=Enabled
  #
  # bucket/key can't be set here directly — Terraform parses the backend
  # block during `terraform init`, before the root module's variables (and
  # terraform.tfvars) exist, so var.xxx is never valid inside `backend {}`.
  # Provide them either way:
  #
  #   (a) cp backend.hcl.example backend.hcl, fill in your bucket name, then:
  #         terraform init -backend-config=backend.hcl
  #
  #   (b) or pass them individually:
  #         terraform init \
  #           -backend-config="bucket=<YOUR_BUCKET_NAME>" \
  #           -backend-config="key=event-management/production/terraform.tfstate"
  #
  # (region is hardcoded below — it's not account-specific like bucket/key,
  # so there's nothing to pass at init time for it. If a missing-region
  # error still shows up, you likely have a stale partial backend config
  # cached from an earlier init — run `terraform init -reconfigure`.)
  backend "s3" {
    region  = "ap-southeast-1"
    encrypt = true
    # bucket and key are supplied via -backend-config at init time — see above
  }
}

# ── Default provider (matches var.aws_region) ─────────────────────────────
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ── us-east-1 alias ── CloudFront ACM certificates MUST live in us-east-1,
# regardless of which region the rest of the app (ECS, RDS, S3, etc.) runs in.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
