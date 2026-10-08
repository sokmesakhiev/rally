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

  # ── Remote state, deliberately its own root module ───────────────────────
  #
  # This is a separate directory rather than a workspace or a `count` on the
  # production resources, and that is the whole point: `terraform apply` here
  # has no production resources in scope, so the worst possible staging
  # mistake cannot reach the cluster serving customers. The cost is some
  # duplication with ../ — accepted, because the alternative is reviewing
  # every staging plan for accidental production diffs.
  #
  # Same bucket as production, different key. Initialise with:
  #
  #   cp backend.hcl.example backend.hcl   # fill in the bucket
  #   terraform init -backend-config=backend.hcl
  #
  # bucket/key can't be literals here for the same reason as production's:
  # the backend block is parsed before variables exist.
  backend "s3" {
    region  = "ap-southeast-1"
    encrypt = true
  }
}

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

# CloudFront ACM certificates must live in us-east-1 whatever region the rest
# of the stack runs in — same constraint as production.
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

locals {
  prefix = "${var.app_name}-${var.environment}"

  custom_api_domain      = var.api_domain != ""
  custom_frontend_domain = var.frontend_domain != ""

  use_route53_for_frontend = local.custom_frontend_domain && var.route53_zone_id != ""
  use_route53_for_api      = local.custom_api_domain && var.route53_zone_id != ""

  # Thruster's listen port, baked into backend/Dockerfile as `HTTP_PORT=3001`.
  # Kamal's proxy defaults to forwarding to port 80, so this has to be passed
  # explicitly in deploy.staging.yml — getting it wrong presents as the proxy
  # never finding a healthy container, with nothing wrong in the app logs.
  app_port = 3001
}

# ── The default VPC, on purpose ───────────────────────────────────────────
#
# Production builds its own VPC with public and private subnets. Staging uses
# the account's default VPC and puts the single instance in a public subnet
# with an Elastic IP.
#
# Two reasons. A NAT gateway is the most expensive thing in the production
# network and exists so that private-subnet tasks can reach the internet;
# with one box that has a public IP there is nothing to NAT. And referencing
# production's VPC from here would couple the two states together through a
# remote-state data source, which is exactly the coupling this directory
# exists to avoid.
#
# The consequence to know: the database is a container on this instance, not
# an RDS instance in a private subnet, so "staging is reachable from the
# internet" is a property of the box's security group alone. Postgres is
# published to 127.0.0.1 only (see deploy.staging.yml) and the group below
# opens nothing but SSH, HTTP and HTTPS.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Canonical's Ubuntu 24.04 LTS, x86_64 — matching the image architecture the
# backend is built for (`builder.arch: amd64`). An arm64 instance would be
# cheaper per hour and would refuse to run the image.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
