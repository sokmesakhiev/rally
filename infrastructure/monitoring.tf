# ── Monitoring ────────────────────────────────────────────────────────────────
#
# The first alarms in this stack. They exist because of one specific gap: the
# Solid Queue worker task has no ECS healthCheck, on purpose (see the long
# comment in ecs.tf), which leaves "supervisor alive but not doing work"
# undetectable from the ECS side. That gap stopped being theoretical when
# certificate generation moved onto the worker — and the precedent is bad:
# GenerateCertificatesJob was absent from recurring.yml for months and nothing
# noticed, because nothing was watching for jobs *not* happening.
#
# Everything here is CloudWatch-native. There is deliberately no Lambda, no VPC
# ENI and no extra deployment artifact; see backend/app/jobs/worker_liveness_job.rb
# for why the signal is a log line rather than a reading of
# solid_queue_processes.last_heartbeat_at.

# ── Notification ──────────────────────────────────────────────────────────────

resource "aws_sns_topic" "alarms" {
  name = "${local.prefix}-alarms"
}

# Email is the whole delivery mechanism for now. Deliberately driven by a
# variable rather than hardcoded: the address that should receive a 3am page is
# a decision for whoever operates this, and it changes independently of the
# infrastructure.
#
# count, not a conditional inside the resource, so that leaving alarm_email
# empty produces no subscription at all rather than an invalid one.
resource "aws_sns_topic_subscription" "alarms_email" {
  count = var.alarm_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ── Worker liveness ───────────────────────────────────────────────────────────

# WorkerLivenessJob writes one JSON line every five minutes. The filter counts
# them; the alarm fires when they stop.
#
# The pattern matches the JSON field rather than a substring of the raw line, so
# it cannot be tripped by the string "solid_queue.liveness" appearing inside an
# error message or a stack trace — which is exactly the situation where a false
# "everything is fine" would be most expensive.
resource "aws_cloudwatch_log_metric_filter" "worker_liveness" {
  name           = "${local.prefix}-worker-liveness"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.event = \"solid_queue.liveness\" }"

  metric_transformation {
    name      = "WorkerLiveness"
    namespace = "Rally/SolidQueue"
    value     = "1"

    # Without this, a period with no matching lines reports *no data* rather
    # than zero. That distinction is the whole alarm: `treat_missing_data`
    # below can cover it, but an explicit zero is what makes the metric
    # readable on a graph and what makes the alarm's own history honest about
    # when the worker was actually down.
    default_value = "0"
  }
}

# Fifteen minutes is three expected lines. One missed period is normal — a
# deploy severs the worker mid-schedule, and Solid Queue's next tick picks it
# up — so alarming on a single gap would page on every release. Three
# consecutive misses is not a deploy.
#
# If config/recurring.yml's `worker_liveness` schedule is ever lengthened, this
# window has to grow with it or a healthy worker starts paging. There's a spec
# pinning the schedule for that reason (spec/jobs/worker_liveness_job_spec.rb).
resource "aws_cloudwatch_metric_alarm" "worker_liveness" {
  alarm_name        = "${local.prefix}-worker-not-running-jobs"
  alarm_description = <<-DESC
    No solid_queue.liveness line for 15 minutes. The Solid Queue worker is not
    executing scheduled jobs.

    What is broken while this is firing: certificates are not being issued,
    abandoned registrations are not releasing their capacity (so events look
    full when they aren't), certificate previews are not being swept from S3,
    and support reply fallback emails are not going out.

    First checks: does the worker service have a RUNNING task
    (${local.prefix}-worker)? Does the log group show a crash loop? Is
    ecs_worker_desired_count zero? If the task is running and quiet, the
    supervisor is wedged — stop the task and let ECS replace it.
  DESC

  namespace   = "Rally/SolidQueue"
  metric_name = "WorkerLiveness"
  statistic   = "Sum"

  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # A worker that has stopped logging and a log pipeline that has stopped
  # delivering are indistinguishable from here, and both mean "you no longer
  # know whether jobs are running". Treating the silence as healthy is the one
  # reading that would let this fail the way GenerateCertificatesJob did.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ── Worker capacity ───────────────────────────────────────────────────────────

# The complement to the liveness alarm, and a genuinely different failure: this
# one catches the task not existing (crash loop, scaled to zero, a deploy that
# never stabilised), where liveness catches it existing but not working.
#
# Cheap to have both — this metric is native, needs no code, and fires faster
# than the 15-minute liveness window.
resource "aws_cloudwatch_metric_alarm" "worker_no_running_tasks" {
  alarm_name        = "${local.prefix}-worker-no-tasks"
  alarm_description = <<-DESC
    The ${local.prefix}-worker service has no running task. Jobs are queuing but
    nothing is claiming them; they are not lost, and will drain once a task comes
    back. Check the service's events tab and the log group for a crash on boot.
  DESC

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  statistic   = "Average"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.worker.name
  }

  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # Deliberately NOT breaching, unlike the liveness alarm above. Container
  # Insights stops publishing for a service scaled to zero, so `breaching`
  # would page continuously whenever ecs_worker_desired_count is intentionally
  # zero. The liveness alarm covers that case anyway, and covers it correctly.
  treat_missing_data = "missing"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ── API availability ──────────────────────────────────────────────────────────

# Not strictly part of the worker gap, but it is one resource and it closes the
# other half of "is anything running": the API has a health check, so ECS
# restarts it, but nothing tells a human that it has been restarting all night.
resource "aws_cloudwatch_metric_alarm" "api_unhealthy_hosts" {
  alarm_name        = "${local.prefix}-api-unhealthy"
  alarm_description = "The API target group has no healthy target. The site is down."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HealthyHostCount"
  statistic   = "Minimum"

  dimensions = {
    TargetGroup  = aws_lb_target_group.app.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }

  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}
