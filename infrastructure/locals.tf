locals {
  prefix = "${var.app_name}-${var.environment}"

  # Two availability zones for HA without excessive NAT cost
  azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
  ]

  # CIDR blocks
  vpc_cidr             = "10.0.0.0/16"
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

  # App port
  app_port = 3001

  # Feature flags
  custom_api_domain      = var.api_domain != ""
  custom_frontend_domain = var.frontend_domain != ""

  # A custom domain can be hosted anywhere (Cloudflare, Namecheap, etc.) —
  # route53_zone_id is specifically "is Route 53 the DNS host, so Terraform
  # can create validation/alias records itself." When a domain is set but
  # route53_zone_id isn't, we still create the ACM certificate (so a domain
  # host elsewhere has something to validate), just skip the Route53 record
  # resources and the aws_acm_certificate_validation wait — the relevant
  # outputs (api_cert_validation_record, frontend_cert_validation_records)
  # print what to paste into the external DNS host instead. See README's
  # "Using a domain hosted outside Route 53" section.
  use_route53_for_api      = local.custom_api_domain && var.route53_zone_id != ""
  use_route53_for_frontend = local.custom_frontend_domain && var.route53_zone_id != ""

  # Effective JWT secret (variable takes precedence over generated)
  effective_jwt_secret = var.jwt_secret != "" ? var.jwt_secret : random_password.jwt_secret.result

  # DATABASE_URL constructed after RDS is created (see secrets.tf)
  # Referenced as: local.database_url
}
