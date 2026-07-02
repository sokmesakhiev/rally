# ── Backend ───────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "ALB DNS name. Set VITE_API_URL=https://<this value> when building the frontend."
  value       = aws_lb.main.dns_name
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

# ── ECS ───────────────────────────────────────────────────────────────────────

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.app.name
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

    1. Build and push your backend image:
       ./scripts/deploy.sh

    2. Build the frontend pointing at your API:
       cd frontend
       VITE_API_URL="${local.custom_api_domain ? "https://${var.api_domain}" : "http://${aws_lb.main.dns_name}"}" npm run build
       aws s3 sync dist/ s3://${aws_s3_bucket.frontend.bucket} --delete
       aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.frontend.id} --paths "/*"

    3. Frontend URL: ${local.custom_frontend_domain ? "https://${var.frontend_domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}"}
  EOT
}
