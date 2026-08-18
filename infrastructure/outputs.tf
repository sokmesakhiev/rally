# ── Backend ───────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB DNS name. Set VITE_API_URL=https://<this value> when building the frontend."
  value       = aws_lb.main.dns_name
}

# Only meaningful when api_domain is set and route53_zone_id isn't (an
# external DNS host like Cloudflare or Namecheap). Add this as a CNAME at
# your DNS host — ACM's crawler auto-validates and issues the cert once it
# sees it (usually a few minutes; no further terraform apply needed). Null
# when route53_zone_id owns the zone, since Terraform creates that record
# itself.
output "api_cert_validation_record" {
  description = "CNAME to add at your DNS host to validate the API's ACM certificate (external DNS only)."
  value = local.custom_api_domain && !local.use_route53_for_api ? {
    name  = tolist(aws_acm_certificate.api[0].domain_validation_options)[0].resource_record_name
    type  = tolist(aws_acm_certificate.api[0].domain_validation_options)[0].resource_record_type
    value = tolist(aws_acm_certificate.api[0].domain_validation_options)[0].resource_record_value
  } : null
}

output "api_url" {
  description = "Full API base URL (custom domain if configured, otherwise ALB DNS)"
  value       = local.custom_api_domain ? "https://${var.api_domain}" : "http://${aws_lb.main.dns_name}"
}

# ── Frontend ──────────────────────────────────────────────────────────────────

output "cloudfront_domain" {
  description = "CloudFront distribution domain. Use this (or your custom domain) for the frontend."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

# Same idea as api_cert_validation_record, but a list — the frontend cert
# covers two names (the apex and "www."), so there are two CNAMEs to add.
# Empty when frontend_domain isn't set or route53_zone_id owns the zone.
output "frontend_cert_validation_records" {
  description = "CNAMEs to add at your DNS host to validate the frontend's ACM certificate (external DNS only)."
  value = local.custom_frontend_domain && !local.use_route53_for_frontend ? [
    for dvo in aws_acm_certificate.frontend[0].domain_validation_options : {
      domain = dvo.domain_name
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      value  = dvo.resource_record_value
    }
  ] : []
}

output "frontend_url" {
  description = "Frontend URL"
  value       = local.custom_frontend_domain ? "https://${var.frontend_domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "frontend_bucket_name" {
  description = "S3 bucket that holds the built frontend assets"
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — needed to invalidate the cache after a frontend deploy"
  value       = aws_cloudfront_distribution.frontend.id
}

# ── Container registry ────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "ECR repository URL. Tag and push images here."
  value       = aws_ecr_repository.app.repository_url
}

# Bare name only (no registry host) — this is what the deploy-backend GitHub
# Actions job's ECR_REPOSITORY variable must be set to (see
# .github/workflows/deploy.yml, which builds the full "$REGISTRY/$REPOSITORY"
# itself from this plus the ECR login step's registry output). Pasting
# ecr_repository_url there instead doubles the registry host in the pushed
# tag and makes ECR reject the push with "repository ... does not exist".
output "ecr_repository_name" {
  description = "Bare ECR repository name (no registry host) — set the GitHub Actions ECR_REPOSITORY variable to this, not ecr_repository_url."
  value       = aws_ecr_repository.app.name
}

# ── ECS ───────────────────────────────────────────────────────────────────────

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.app.name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for the backend container. Tail after a deploy: aws logs tail <this> --follow --since 10m"
  value       = aws_cloudwatch_log_group.app.name
}

# ── Storage ───────────────────────────────────────────────────────────────────

output "uploads_bucket_name" {
  description = "S3 bucket for Active Storage uploads"
  value       = aws_s3_bucket.uploads.bucket
}

# ── Database ──────────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "RDS endpoint (host only, no port). Not publicly accessible — use a bastion or ECS exec."
  value       = aws_db_instance.main.address
  sensitive   = true
}

# ── Next steps ────────────────────────────────────────────────────────────────

output "next_steps" {
  description = "Quick-start instructions"
  value       = <<-EOT
    ✅  Infrastructure is ready. Next steps:
    ${local.custom_api_domain && !local.use_route53_for_api ? "\n    0a. Add the CNAME from the api_cert_validation_record output at your DNS host (Cloudflare, Namecheap, etc.), then wait for the API's ACM certificate to show \"Issued\" before continuing.\n" : ""}${local.custom_frontend_domain && !local.use_route53_for_frontend ? "\n    0b. Add the two CNAMEs from the frontend_cert_validation_records output at your DNS host, then wait for the frontend's ACM certificate to show \"Issued\" before continuing.\n" : ""}
    1. Build and push your backend image:
       ./scripts/deploy.sh

    2. Build the frontend pointing at your API:
       cd frontend
       VITE_API_URL="${local.custom_api_domain ? "https://${var.api_domain}" : "http://${aws_lb.main.dns_name}"}" npm run build
       aws s3 sync dist/client/ s3://${aws_s3_bucket.frontend.bucket} --delete
       aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.frontend.id} --paths "/*"

    3. Frontend URL: ${local.custom_frontend_domain ? "https://${var.frontend_domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}"}
    ${local.custom_api_domain && !local.use_route53_for_api ? "\n    4. Point api_domain's DNS (at your DNS host) at the alb_dns_name output via CNAME, once its certificate is issued." : ""}${local.custom_frontend_domain && !local.use_route53_for_frontend ? "\n    5. Point frontend_domain and www.<frontend_domain> (at your DNS host) at the cloudfront_domain output via CNAME, once its certificate is issued." : ""}
  EOT
}
