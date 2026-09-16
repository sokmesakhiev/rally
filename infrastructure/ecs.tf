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

# ── Shared container configuration ────────────────────────────────────────────
# The web service and the jobs service run the *same image* and differ only in
# the command they run and a handful of process-sizing variables. Everything
# they must agree on lives here exactly once — two hand-maintained copies of
# this list would drift, and the failure mode is a job that behaves differently
# from the request that enqueued it, which is miserable to diagnose.

locals {
  # Static environment variables (non-sensitive) common to both services.
  app_environment = [
    { name = "RAILS_ENV", value = "production" },
    { name = "RAILS_LOG_TO_STDOUT", value = "true" },
    { name = "RAILS_SERVE_STATIC_FILES", value = "false" },
    { name = "AWS_REGION", value = var.aws_region },
    { name = "AWS_BUCKET", value = aws_s3_bucket.uploads.bucket },
    { name = "FRONTEND_URL", value = local.custom_frontend_domain ? "https://${var.frontend_domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}" },
    { name = "BACKEND_URL", value = local.custom_api_domain ? "https://${var.api_domain}" : "http://${aws_lb.main.dns_name}" },
    { name = "ABA_PAYWAY_BASE_URL", value = var.aba_payway_base_url },
    { name = "MAILER_FROM_EMAIL", value = var.mailer_from_email },
    # Google's OAuth Client ID is not a secret — it's compiled into the
    # frontend JS bundle anyway. The backend only needs it to check the
    # `aud` claim on ID tokens (see AuthController#google).
    { name = "GOOGLE_CLIENT_ID", value = var.google_client_id },
    # Error tracking. Not a secret — a Sentry DSN is a write-only ingest
    # endpoint and is embedded in client bundles by design. Empty leaves
    # Sentry uninitialized and every Sentry call a no-op (see
    # backend/config/initializers/sentry.rb).
    { name = "SENTRY_DSN", value = var.sentry_dsn },
    { name = "SENTRY_ENVIRONMENT", value = var.environment },
  ]

  # Secrets injected at task startup from Secrets Manager.
  # The ECS agent fetches these using the execution role, so they are never
  # visible in the task definition or AWS console.
  #
  # Both services get the full set. The worker needs more of it than it looks:
  # RAILS_MASTER_KEY decrypts organizers' PayWay credentials on Profile, and
  # the ABA keys are used by jobs that poll and reconcile payments.
  app_secrets = [
    { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn },
    { name = "JWT_SECRET", valueFrom = aws_secretsmanager_secret.jwt_secret.arn },
    { name = "RAILS_MASTER_KEY", valueFrom = aws_secretsmanager_secret.rails_master_key.arn },
    { name = "ABA_PAYWAY_MERCHANT_ID", valueFrom = aws_secretsmanager_secret.aba_payway_merchant_id.arn },
    { name = "ABA_PAYWAY_API_KEY", valueFrom = aws_secretsmanager_secret.aba_payway_api_key.arn },
    { name = "RECAPTCHA_SECRET_KEY", valueFrom = aws_secretsmanager_secret.recaptcha_secret_key.arn },
  ]
}

# ── Task Definition: web ──────────────────────────────────────────────────────

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

    # No `command` — the image's own CMD (./bin/thrust ./bin/rails server) is
    # what bin/docker-entrypoint pattern-matches on to decide that *this* task
    # is the one that runs migrations. See the worker task definition below.

    portMappings = [{
      containerPort = local.app_port
      protocol      = "tcp"
    }]

    environment = concat(local.app_environment, [
      { name = "PORT", value = tostring(local.app_port) },
      # Puma's thread count per task. Previously unset, so the whole system ran
      # on config/puma.rb's default of 3 by accident rather than by decision —
      # and that same fallback silently sized the Active Record pool. Now that
      # ActionCable's workers contend for that pool too (see
      # backend/config/database.yml, which derives max_connections from this
      # and ACTION_CABLE_WORKER_POOL_SIZE), it needs to be explicit.
      { name = "RAILS_MAX_THREADS", value = "3" },
      # ActionCable's worker pool: where channel callbacks and broadcasts run.
      { name = "ACTION_CABLE_WORKER_POOL_SIZE", value = "4" },
      # ActionCable refuses connections from any origin not listed here, and
      # the frontend is a different origin than this API. Comma-separated;
      # falls back to FRONTEND_URL in production.rb if unset.
      { name = "ACTION_CABLE_ALLOWED_ORIGINS", value = local.custom_frontend_domain ? "https://${var.frontend_domain}" : "https://${aws_cloudfront_distribution.frontend.domain_name}" },
      # SOLID_QUEUE_IN_PUMA is deliberately absent. It used to be "true", which
      # ran Solid Queue's supervisor inside this Puma process; jobs now run in
      # the separate worker service below, so that a slow LibreOffice render
      # can't take CPU away from request handling and so the two can be sized
      # and scaled independently. config/puma.rb only loads the plugin when the
      # variable is set, so removing it here is the entire app-side switch.
    ])

    secrets = local.app_secrets

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
}

# ── Task Definition: Solid Queue worker ───────────────────────────────────────
# Same image, different command. Everything about this task exists so that job
# execution and request handling stop competing: Certificates::RenderPdf shells
# out to LibreOffice, which is slow and memory-hungry, and until now it did that
# inside the Puma process serving the API.

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.prefix}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_worker_task_cpu
  memory                   = var.ecs_worker_task_memory

  execution_role_arn = aws_iam_role.ecs_execution.arn
  # Deliberately the same task role as the web service, not a narrower one.
  # Jobs write certificate PDFs to the uploads bucket and send mail through
  # SES — the same permissions the web task already holds, because these jobs
  # were running inside the web task until now. Splitting the role would be a
  # separate change with its own blast radius; doing it here would mean this
  # deploy could fail for a reason unrelated to the split itself.
  task_role_arn = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${aws_ecr_repository.app.repository_url}:${var.rails_image_tag}"
    essential = true

    # bin/jobs boots Rails and hands off to SolidQueue::Cli, which reads
    # config/queue.yml (dispatcher + workers) and config/recurring.yml
    # (the hourly sweeps). Both of those now run *here* rather than in Puma.
    command = ["./bin/jobs"]

    # No portMappings: nothing connects to this task. It reaches out to
    # Postgres, S3 and SES and is never reached from outside.

    environment = concat(local.app_environment, [
      # config/database.yml's `default:` block keys its max_connections on this
      # variable, which is what sizes the `queue` role. Solid Queue's own
      # estimate (Configuration#estimated_database_pool_size) is the worker's
      # thread count plus two — one for its polling thread, one for the
      # heartbeat — so 3 threads needs 5, and it prints a warning at boot if
      # the pool is smaller. 6 is that with one spare. Note the supervisor
      # forks the dispatcher and each worker into separate processes, so this
      # is a ceiling *per process*, not for the task as a whole.
      { name = "RAILS_DB_POOL", value = "6" },
      # RAILS_MAX_THREADS is deliberately unset: nothing here serves requests,
      # and Solid Queue's concurrency comes from config/queue.yml instead.
      # Scale job throughput by raising ecs_worker_desired_count, not by
      # raising JOB_CONCURRENCY inside a 0.5 vCPU task.
    ])

    secrets = local.app_secrets

    # No healthCheck, and that is a decision rather than an omission. The
    # supervisor is this container's main process (under the init below), so if
    # it dies the container exits and ECS replaces the task — a liveness probe
    # would only be re-asking a question the exit status already answers. If a
    # *forked* worker dies, the supervisor replaces it without help.
    #
    # The failure a probe can't see either — supervisor alive but wedged — is
    # covered by monitoring.tf's worker-not-running-jobs alarm. This comment
    # used to say that gap "is detectable only from
    # solid_queue_processes.last_heartbeat_at going stale"; that turned out to
    # be wrong twice over, and the alarm deliberately does something else. See
    # backend/app/jobs/worker_liveness_job.rb: the heartbeat is written by its
    # own thread and keeps ticking on a worker that is executing nothing, so it
    # answers the same question the exit status already does.
    #
    # One consequence worth knowing: with no health check, ECS's deployment
    # circuit breaker treats "reached RUNNING" as success, so it catches a
    # crash-on-boot but not a worker that boots and then fails every job. That
    # case is exactly what the liveness alarm catches, 15 minutes later.

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        # Same log group as the API, different stream prefix — one place to
        # look when tracing a request into the job it enqueued.
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "worker"
      }
    }

    # An init process reaps the supervisor's forked children and forwards
    # SIGTERM to it on deploy, which is how Solid Queue gets to shut down
    # gracefully rather than being killed mid-job. Also what makes
    # `aws ecs execute-command` usable here.
    linuxParameters = {
      initProcessEnabled = true
    }
  }])
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
  # With Route 53 as the DNS host, wait for aws_acm_certificate_validation so
  # the listener only ever references a fully-validated cert. With an
  # external DNS host (Cloudflare, etc.) there's no Terraform-managed record
  # to wait on — attach the raw certificate directly. It's valid immediately
  # once you add the CNAME the api_cert_validation_record output prints and
  # ACM's crawler picks it up (usually a few minutes, occasionally longer);
  # until then AWS still attaches it, it's just not yet trusted by clients.
  certificate_arn = local.use_route53_for_api ? aws_acm_certificate_validation.api[0].certificate_arn : aws_acm_certificate.api[0].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ── ACM Certificate for the API domain ───────────────────────────────────────
# Created whenever api_domain is set, regardless of DNS host — see
# use_route53_for_api in locals.tf. With an external DNS host, the
# api_cert_validation_record output tells you what CNAME to add by hand.

resource "aws_acm_certificate" "api" {
  count = local.custom_api_domain ? 1 : 0

  domain_name       = var.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "api_cert_validation" {
  for_each = local.use_route53_for_api ? {
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
  count = local.use_route53_for_api ? 1 : 0

  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [for record in aws_route53_record.api_cert_validation : record.fqdn]
}

# Route 53 A record pointing to the ALB. Only created when Route 53 owns the
# zone — with an external DNS host, add a CNAME for api_domain pointing at
# the alb_dns_name output instead (see README).
resource "aws_route53_record" "api" {
  count = local.use_route53_for_api ? 1 : 0

  zone_id = var.route53_zone_id
  name    = var.api_domain
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# ── ECS Services ──────────────────────────────────────────────────────────────
#
# Both task definitions above used to carry `ignore_changes =
# [container_definitions]`, and the web service `ignore_changes =
# [task_definition]`, on the stated grounds that "the deploy script manages
# these". It doesn't: scripts/deploy.sh and .github/workflows/deploy.yml both
# only run `aws ecs update-service --force-new-deployment`, which re-runs the
# revision the service already points at. Nothing outside Terraform ever
# registers a revision, and var.rails_image_tag is the mutable ":latest", so
# container_definitions never actually drifted — the ignores were guarding
# against drift this pipeline doesn't produce.
#
# What they *did* do was make every environment change unappliable: Terraform
# would refuse to update the definition, and even if it had, the service would
# have stayed pinned to the old revision. That is why SOLID_QUEUE_IN_PUMA could
# not simply be deleted, and why ENABLE_PING_CHANNEL was awkward to set. With
# the ignores gone, `terraform apply` registers a revision and rolls the
# service, which is what one would have assumed it did all along.
#
# desired_count stays ignored on both: that is genuinely adjusted out of band.

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
    # Scaled out of band (console, autoscaling, an incident) — Terraform
    # shouldn't pull it back to the variable's value on the next apply.
    ignore_changes = [desired_count]
  }
}

resource "aws_ecs_service" "worker" {
  name            = "${local.prefix}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.ecs_worker_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true

  # Matches the web service, and Solid Queue is built for it: workers claim
  # jobs by inserting into solid_queue_claimed_executions, which has a unique
  # index on job_id, so an old and a new supervisor overlapping during a deploy
  # split the work rather than duplicating it. The recurring sweeps are safe for
  # the same reason — solid_queue_recurring_executions is uniquely indexed on
  # (task_key, run_at), so N schedulers still enqueue each occurrence once.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  # No load_balancer block: this service has nothing listening. It reuses the
  # ECS security group, whose ALB ingress rule is simply unused here — a
  # dedicated egress-only group would be tidier but buys no isolation, since
  # both services already talk to the same database with the same credentials.

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Deliberately does not depend on aws_lb_listener.http — jobs do not need the
  # load balancer to exist, and coupling them would mean an ALB problem could
  # block a worker deploy.
  depends_on = [aws_iam_role_policy_attachment.ecs_execution_managed]

  lifecycle {
    ignore_changes = [desired_count]
  }
}
