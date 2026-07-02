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

  # Effective JWT secret (variable takes precedence over generated)
  effective_jwt_secret = var.jwt_secret != "" ? var.jwt_secret : random_password.jwt_secret.result

  # DATABASE_URL constructed after RDS is created (see secrets.tf)
  # Referenced as: local.database_url
}
