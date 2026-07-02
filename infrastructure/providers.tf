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
  #     --region us-east-1
  #
  #   aws s3api put-bucket-versioning \
  #     --bucket <YOUR_BUCKET_NAME> \
  #     --versioning-configuration Status=Enabled
  #
  # Then init with:
  #   terraform init \
  #     -backend-config="bucket=<YOUR_BUCKET_NAME>" \
  #     -backend-config="key=event-management/production/terraform.tfstate" \
  #     -backend-config="region=us-east-1"
  #
  backend "s3" {
    encrypt = true
    # bucket, key, and region are supplied via -backend-config flags above
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

# ── us-east-1 alias ── CloudFront ACM certificates MUST live in us-east-1
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
