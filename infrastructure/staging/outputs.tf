# Every value the staging CD workflow and deploy.staging.yml need, so neither
# carries a hardcoded ARN or IP. `scripts/deploy.sh` reads production's
# equivalents the same way; CI can't (no state access) and uses repo
# variables/secrets instead — see docs/staging-deployment.md for which output
# feeds which.

output "app_public_ip" {
  description = "Elastic IP of the staging box — the A record for api_domain, and KAMAL_HOST."
  value       = aws_eip.app.public_ip
}

output "api_url" {
  description = "BACKEND_URL for the app and VITE_API_URL for the frontend build."
  value       = "https://${var.api_domain}"
}

# Kamal composes the image reference as `registry.server` + "/" + `image`, so
# these are two separate values and NOT the repository URL. Passing the full
# URL as `image` yields
# `123.dkr.ecr…amazonaws.com/123.dkr.ecr…amazonaws.com/rally-staging-api`,
# which fails at push with an authentication error rather than a name error.
output "ecr_registry" {
  description = "STAGING_ECR_REGISTRY — Kamal's `registry.server`."
  value       = split("/", aws_ecr_repository.api.repository_url)[0]
}

output "ecr_repository_name" {
  description = "STAGING_ECR_IMAGE — Kamal's `image`. NOT production's repository; see storage.tf."
  value       = aws_ecr_repository.api.name
}

output "ecr_repository_url" {
  description = "The two above joined. For `docker pull` by hand; not for Kamal."
  value       = aws_ecr_repository.api.repository_url
}

output "uploads_bucket" {
  description = "AWS_BUCKET for Active Storage."
  value       = aws_s3_bucket.uploads.id
}

output "frontend_bucket" {
  description = "Target for `aws s3 sync` in the staging frontend job."
  value       = aws_s3_bucket.frontend.id
}

output "cloudfront_distribution_id" {
  description = "For the cache invalidation after a frontend deploy."
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_url" {
  description = "FRONTEND_URL for the app and VITE_BASE_URL for the build (which fails without it)."
  value       = local.custom_frontend_domain ? "https://${var.frontend_domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

# ── DNS to create by hand when Route 53 doesn't own the zone ───────────────

output "dns_records_to_create" {
  description = <<-EOT
    What to add at your DNS host when route53_zone_id is empty. The API record
    must exist and resolve BEFORE the first `kamal deploy`: Kamal's proxy gets
    its certificate over HTTP-01, which means Let's Encrypt has to reach this
    box by name.
  EOT
  value = local.use_route53_for_api && local.use_route53_for_frontend ? "none — Route 53 records are managed by Terraform" : join("\n", compact([
    local.use_route53_for_api ? "" : "A     ${var.api_domain} -> ${aws_eip.app.public_ip}",
    local.custom_frontend_domain && !local.use_route53_for_frontend ? "CNAME ${var.frontend_domain} -> ${aws_cloudfront_distribution.frontend.domain_name}" : "",
  ]))
}

output "frontend_cert_validation_records" {
  description = "ACM validation records to add by hand when Route 53 doesn't own the zone."
  value = local.custom_frontend_domain && !local.use_route53_for_frontend ? [
    for dvo in aws_acm_certificate.frontend[0].domain_validation_options :
    "${dvo.resource_record_type} ${dvo.resource_record_name} -> ${dvo.resource_record_value}"
  ] : []
}
