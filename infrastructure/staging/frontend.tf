# ── The staging SPA: S3 + CloudFront ───────────────────────────────────────
#
# Mirrors production's delivery rather than serving the build off the EC2 box,
# because several of the things most likely to break on a release are
# properties of *this* path and nothing else: the 404→index rewrite that makes
# client-side routing work, CloudFront's cache on a redeploy, and
# `sitemap.xml` having to exist as a real object in the bucket rather than
# being answered by a route (see .claude/rules/frontend-conventions.md — a
# sitemap route returned the SPA shell with a 200 for weeks).
resource "aws_s3_bucket" "frontend" {
  bucket = "${local.prefix}-frontend"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.prefix}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}

resource "aws_acm_certificate" "frontend" {
  count = local.custom_frontend_domain ? 1 : 0

  provider          = aws.us_east_1
  domain_name       = var.frontend_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "frontend_cert_validation" {
  for_each = local.use_route53_for_frontend ? {
    for dvo in aws_acm_certificate.frontend[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "frontend" {
  count = local.use_route53_for_frontend ? 1 : 0

  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.frontend[0].arn
  validation_record_fqdns = [for r in aws_route53_record.frontend_cert_validation : r.fqdn]
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "${local.prefix} frontend"

  # No www alias, unlike production — nobody types a staging hostname.
  aliases = local.custom_frontend_domain ? [var.frontend_domain] : []

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.frontend.bucket}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "S3-${aws_s3_bucket.frontend.bucket}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # CachingOptimized, the same managed policy production uses. Deliberately
    # not a shorter-TTL staging-only policy: a cache that behaves differently
    # here is a cache whose production behaviour is untested, and the deploy
    # job invalidates anyway.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # SPA routing. The build is one prerendered shell plus client-side routes,
  # so every path other than the assets is a 404 at the origin.
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.custom_frontend_domain ? null : true
    acm_certificate_arn = local.custom_frontend_domain ? (
      local.use_route53_for_frontend ? aws_acm_certificate_validation.frontend[0].certificate_arn : aws_acm_certificate.frontend[0].arn
    ) : null
    ssl_support_method       = local.custom_frontend_domain ? "sni-only" : null
    minimum_protocol_version = local.custom_frontend_domain ? "TLSv1.2_2021" : null
  }
}

resource "aws_route53_record" "frontend" {
  count = local.use_route53_for_frontend ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.frontend_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}
