variable "aws_region" {
  description = "Region for everything except the CloudFront certificate."
  type        = string
  default     = "ap-southeast-1"
}

variable "app_name" {
  description = "Resource name prefix. Must match production's so ECR/S3 names read consistently."
  type        = string
  default     = "rally"
}

variable "environment" {
  description = "Environment name, used in the resource prefix."
  type        = string
  default     = "staging"
}

# ── The box ────────────────────────────────────────────────────────────────

variable "instance_type" {
  description = <<-EOT
    Instance type for the staging box. It runs the Rails web container, the
    Solid Queue worker container, a Postgres container, and the Kamal proxy —
    plus LibreOffice when a certificate renders, which alone peaks around
    180 MB RSS per conversion. t3.small (2 GiB) is the floor; t3.medium if
    certificate rendering is being exercised in earnest.
  EOT
  type        = string
  default     = "t3.small"
}

variable "root_volume_gb" {
  description = "Root volume size. Holds Docker images (several versions, Kamal keeps the previous one for rollback) plus the Postgres volume."
  type        = number
  default     = 30
}

variable "ssh_public_key" {
  description = "Public key for the deploy user. CI uses the matching private key to let Kamal in, so this is not optional."
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach port 22. GitHub-hosted runners have no stable
    egress range, so CI needs 0.0.0.0/0 here unless you run a self-hosted
    runner or add a step that opens the group for the length of the deploy.
    That is the honest trade of deploying to a box over SSH from GitHub.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── Domains ────────────────────────────────────────────────────────────────

variable "api_domain" {
  description = <<-EOT
    Hostname for the staging API, e.g. api.staging.example.com. **Required in
    practice, not optional**: config/environments/production.rb hardcodes
    `force_ssl = true`, and staging runs as RAILS_ENV=production, so a bare IP
    would redirect every request to https://<ip> and fail certificate
    validation. Kamal's proxy gets a Let's Encrypt certificate for this name,
    which needs an A record pointing at the Elastic IP *before* the first
    deploy — HTTP-01 validation has to reach the box.
  EOT
  type        = string
}

variable "frontend_domain" {
  description = "Hostname for the staging SPA, e.g. staging.example.com. Empty uses the CloudFront domain, which is fine for staging."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 zone ID. Empty means Terraform creates no DNS records and the outputs print what to add by hand."
  type        = string
  default     = ""
}
