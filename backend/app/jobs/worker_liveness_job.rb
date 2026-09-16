# frozen_string_literal: true

# Proves the Solid Queue worker can still execute a scheduled job, by doing the
# cheapest possible one and logging a line a CloudWatch metric filter counts.
# See infrastructure/monitoring.tf for the filter and the alarm.
#
# ── Why this exists rather than an alarm on last_heartbeat_at ────────────────
# The worker task deliberately has no ECS healthCheck (see the comment in
# infrastructure/ecs.tf): the supervisor is PID 1, so a dead supervisor exits
# the container and ECS replaces it. The failure no probe catches is a
# supervisor that is *alive but not getting work done*.
#
# The obvious fix is an alarm on solid_queue_processes.last_heartbeat_at going
# stale. Two problems with that, one practical and one substantive:
#
#   * Practical: that column lives in Postgres, and CloudWatch cannot read
#     Postgres. Bridging it needs either a Lambda in the VPC or a reporter
#     thread in the *web* task — the worker can't be trusted to report on
#     itself, and a recurring job can't either, since recurring jobs are
#     exactly what we're trying to prove still run.
#   * Substantive, and the reason this approach won: **the heartbeat is
#     written by its own thread**, independently of whether any job ever
#     runs. A worker wedged on a stuck LibreOffice render, or one whose
#     claimed executions are never released, keeps its heartbeat perfectly
#     fresh while doing nothing. The heartbeat answers "is the process
#     alive?", which is the question ECS already answers.
#
# This job answers the question that actually matters: scheduler enqueued it,
# dispatcher moved it to ready, a worker claimed it, and it ran. Everything
# in that chain has to be healthy for the line to appear. If it stops
# appearing, `GenerateCertificatesJob` and the rest of recurring.yml have
# stopped too — which is the failure this whole alarm exists to catch, and
# which went unnoticed for months when GenerateCertificatesJob was simply
# never scheduled at all.
class WorkerLivenessJob < ApplicationJob
  queue_as :default

  # A backlog this size means the worker is running but not keeping up, which
  # is a different alarm (and a different response — scale out) from "the
  # worker is dead". Logged rather than raised so the liveness line itself
  # always gets written: a job that raised here would stop reporting at the
  # exact moment the numbers became interesting.
  BACKLOG_WARNING_THRESHOLD = 500

  def perform
    payload = {
      event: "solid_queue.liveness",
      ready: ready_count,
      scheduled: scheduled_count,
      failed: failed_count,
      oldest_ready_age_seconds: oldest_ready_age_seconds,
      processes: process_count
    }

    # One line, one JSON object, no interpolation of user data — the metric
    # filter matches on the `event` field, and the rest is there for whoever
    # opens the log group after the alarm fires. Emitted at INFO because
    # production's log level is :info; at :warn this would be silent in the
    # one place it needs not to be.
    Rails.logger.info(payload.to_json)

    return unless payload[:ready] >= BACKLOG_WARNING_THRESHOLD

    Rails.logger.warn(
      { event: "solid_queue.backlog", ready: payload[:ready] }.to_json
    )
  end

  private

  # Guarded because Solid Queue's models only exist in production (the gem is
  # in Gemfile's :production group), so in development and test this job has
  # to degrade to "I ran" rather than raising NameError. The liveness line is
  # still emitted — which is what the specs assert.
  def solid_queue?
    defined?(SolidQueue::ReadyExecution)
  end

  def ready_count
    solid_queue? ? SolidQueue::ReadyExecution.count : 0
  end

  def scheduled_count
    solid_queue? ? SolidQueue::ScheduledExecution.count : 0
  end

  def failed_count
    solid_queue? ? SolidQueue::FailedExecution.count : 0
  end

  def process_count
    solid_queue? ? SolidQueue::Process.count : 0
  end

  # How long the oldest ready job has been waiting. Zero when the queue is
  # empty, which is the normal state — this is the number that distinguishes
  # "quiet" from "stuck", since both look the same from job counts alone if
  # the backlog is small.
  def oldest_ready_age_seconds
    return 0 unless solid_queue?

    oldest = SolidQueue::ReadyExecution.minimum(:created_at)
    oldest ? (Time.current - oldest).round : 0
  end
end
