# ── CloudWatch Log Group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.prefix}"
  retention_in_days = 30
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ── Task Definition ───────────────────────────────────────────────────────────

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory

  execution_role_arn = aws_iam_role.ecs_execution.arn # pull images, get secrets
  task_role_arn      = aws_iam_role.ecs_task.arn      # S3, SSM exec

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${aws_ecr_repository.app.repository_url}:${var.rails_image_tag}"
    essential = true

    portMappings = [{
      containerPort = local.app_port
      protocol      = "tcp"
    }]

    # Static environment variables (non-sensitive)
    environment = [
      { name = "RAILS_ENV",              value = "production" },
      { name = "RAILS_LOG_TO_STDOUT",    value = "true" },
      { name = "RAILS_SERVE_STATIC_FILES", value = "false" },
      { name = "PORT",                   value = tostring(local.app_port) },
      { name = "AWS_REGION",             value = var.aws_region },
      { name = "AWS_BUCKET",             value = aws_s3_bucket.uploads.bucket },
      { name = "FRONTEND_URL",           value = local.custom_frontend_domain ? "https://${var.frontend_domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}" },
      { name = "BACKEND_URL",            value = local.custom_api_domain ? "https://${var.api_domain}" : "http://${aws_lb.main.dns_name}" },
      { name = "ABA_PAYWAY_BASE_URL",    value = var.aba_payway_base_url },
      { name = "MAILER_FROM_EMAIL",      value = var.mailer_from_email },
    ]

    # Secrets injected at task startup from Secrets Manager
    # The ECS agent fetches these using the execution role, so they are never
    # visible in the task definition or AWS console.
    secrets = [
      { name = "DATABASE_URL",             valueFrom = aws_secretsmanager_secret.database_url.arn },
      { name = "JWT_SECRET",               valueFrom = aws_secretsmanager_secret.jwt_secret.arn },
      { name = "RAILS_MASTER_KEY",         valueFrom = aws_secretsmanager_secret.rails_master_key.arn },
      { name = "ABA_PAYWAY_MERCHANT_ID",   valueFrom = aws_secretsmanager_secret.aba_payway_merchant_id.arn },
      { name = "ABA_PAYWAY_API_KEY",       valueFrom = aws_secretsmanager_secret.aba_payway_api_key.arn },
    ]

    # Health check — Rails 8 ships the /up endpoint out of the box
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:${local.app_port}/up || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60 # allow time for migrations on first boot
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }

    # Enables `aws ecs execute-command` for live debugging
    linuxParameters = {
      initProcessEnabled = true
    }
  }])

  lifecycle {
    # Image tag is managed by the deploy script, not Terraform.
    # Running `terraform apply` won't roll back a deploy.
    ignore_changes = [container_definitions]
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # Protect against accidental deletion of the load balancer
  enable_deletion_protection = false

  tags = { Name = "${local.prefix}-alb" }
}

resource "aws_lb_target_group" "app" {
  name        = "${local.prefix}-api-tg"
  port        = local.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for Fargate

  health_check {
    path                = "/up"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  # Brief deregistration delay for zero-downtime deploys
  deregistration_delay = 30

  tags = { Name = "${local.prefix}-api-tg" }
}

# HTTP listener — redirects to HTTPS when a domain is configured; forwards directly otherwise.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.custom_api_domain ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = local.custom_api_domain ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "forward" {
      for_each = local.custom_api_domain ? [] : [1]
      content {
        target_group {
          arn = aws_lb_target_group.app.arn
        }
      }
    }
  }
}

# HTTPS listener — created only when a custom API domain is provided.
resource "aws_lb_listener" "https" {
  count = local.custom_api_domain ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.api[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ── ACM Certificate for the API domain ───────────────────────────────────────

resource "aws_acm_certificate" "api" {
  count = local.custom_api_domain ? 1 : 0

  domain_name       = var.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = local.custom_api_domain ? {
    for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.route53_zone_id
}

resource "aws_acm_certificate_validation" "api" {
  count = local.custom_api_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [for record in aws_route53_record.api_cert_validation : record.fqdn]
}

# Route 53 A record pointing to the ALB
resource "aws_route53_record" "api" {
  count = local.custom_api_domain ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.api_domain
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# ── ECS Service ───────────────────────────────────────────────────────────────

resource "aws_ecs_service" "app" {
  name            = "${local.prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.ecs_desired_count
  launch_type     = "FARGATE"

  # Enable ECS Exec for live debugging
  enable_execute_command = true

  # Rolling deploy: keep minimum 100% healthy during deploy
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "api"
    container_port   = local.app_port
  }

  # Circuit breaker: rolls back to previous task definition on repeated failures
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_execution_managed,
  ]

  lifecycle {
    # task_definition and desired_count are managed by the deploy script
    ignore_changes = [task_definition, desired_count]
  }
}
