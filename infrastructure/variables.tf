# ── General ───────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources (except CloudFront ACM which is always us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "production"
}

variable "app_name" {
  description = "Short application name used as a prefix in resource names"
  type        = string
  default     = "rally"
}

# ── Domains (optional) ────────────────────────────────────────────────────────
# Leave empty to skip ACM / Route 53 setup and use auto-generated AWS URLs.

variable "api_domain" {
  description = "Custom domain for the API ALB, e.g. api.example.com. Leave empty to skip HTTPS."
  type        = string
  default     = ""
}

variable "frontend_domain" {
  description = "Custom domain for the CloudFront frontend, e.g. example.com. Leave empty to skip."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID. Required if api_domain or frontend_domain are set."
  type        = string
  default     = ""
}

# ── Database ──────────────────────────────────────────────────────────────────

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "event_management_production"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "rally"
}

variable "db_allocated_storage" {
  description = "Initial storage in GB for RDS"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum storage in GB for RDS auto-scaling"
  type        = number
  default     = 100
}

# ── ECS / Fargate ─────────────────────────────────────────────────────────────

variable "ecs_task_cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 512
}

variable "ecs_task_memory" {
  description = "Fargate task memory in MB"
  type        = number
  default     = 1024
}

variable "ecs_desired_count" {
  description = "Number of ECS tasks to run"
  type        = number
  default     = 1
}

variable "rails_image_tag" {
  description = "Docker image tag to deploy. Updated by the deploy script, not Terraform."
  type        = string
  default     = "latest"
}

# ── Secrets ───────────────────────────────────────────────────────────────────

variable "rails_master_key" {
  description = "Rails master key from backend/config/master.key. Run: cat backend/config/master.key"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret. Leave empty to auto-generate a 64-char random string."
  type        = string
  sensitive   = true
  default     = ""
}

variable "aba_payway_merchant_id" {
  description = "ABA PayWay merchant ID (from ABA Bank — see ABA_PAYWAY_SETUP.md). Required for payments to work."
  type        = string
  sensitive   = true
  default     = ""
}

variable "aba_payway_api_key" {
  description = "ABA PayWay API key used to sign requests (from ABA Bank). Required for payments to work."
  type        = string
  sensitive   = true
  default     = ""
}

variable "aba_payway_base_url" {
  description = "ABA PayWay environment base URL — sandbox until ABA approves production access."
  type        = string
  default     = "https://checkout-sandbox.payway.com.kh"
}

# ── Mail ──────────────────────────────────────────────────────────────────────

variable "mailer_from_email" {
  description = "From address for transactional email, sent via SES. Must be a verified SES identity/domain."
  type        = string
  default     = "Rally <no-reply@example.com>"
}
