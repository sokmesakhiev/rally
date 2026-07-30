# frozen_string_literal: true

# Error tracking and performance monitoring.
#
# Entirely gated on SENTRY_DSN being present: with no DSN, Sentry.init is
# never called and every Sentry.* call in the app becomes a no-op, so
# development, test, and CI send nothing and need no configuration. Same
# opt-in philosophy as the Google Maps / Google OAuth integrations.
return if ENV["SENTRY_DSN"].blank?

Sentry.init do |config|
  config.dsn = ENV.fetch("SENTRY_DSN")

  # Distinguishes production from any future staging environment in the
  # Sentry UI, and lets alert rules target one without the other.
  config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)

  # Ties each error to the deployed commit, which is what makes "which deploy
  # introduced this?" answerable in Sentry.
  #
  # Caveat: GIT_SHA is NOT currently set in production. The ECS task
  # definition is managed by Terraform with ignore_changes on
  # container_definitions and always points at the `:latest` image tag — a
  # deploy just force-pulls that tag rather than registering a new task
  # definition, so there's nowhere for CI to inject the SHA today. Until that
  # changes, release stays nil and Sentry groups everything under one
  # release. Wiring this up properly means having the deploy register a new
  # task definition revision with GIT_SHA in its environment.
  config.release = ENV["GIT_SHA"].presence

  # Breadcrumbs: capture Rails logs and outbound HTTP calls leading up to an
  # error. The HTTP breadcrumbs are the useful ones here — they show the ABA
  # PayWay request/response sequence around a failed payment.
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]

  # Don't report routine client errors as exceptions — a 404 from a mistyped
  # event id or an ActionController::BadRequest is not an incident, and
  # leaving them in drowns real errors in noise. Note ActiveRecord::
  # RecordNotFound is already in Sentry's default ignore list; it's repeated
  # explicitly because several controllers rescue it into a 404 JSON response
  # and it should stay ignored even if that changes.
  config.excluded_exceptions += [
    "ActiveRecord::RecordNotFound",
    "ActionController::RoutingError",
    "ActionController::ParameterMissing",
    "ActionController::BadRequest"
  ]

  # Performance monitoring. 10% of requests is enough to see latency trends
  # (notably the two synchronous ABA PayWay calls) without a large bill; the
  # sampler drops health checks entirely since a constant stream of ALB polls
  # would otherwise dominate the sample.
  config.traces_sampler = lambda do |sampling_context|
    transaction_context = sampling_context[:transaction_context] || {}
    name = transaction_context[:name].to_s

    next 0.0 if name.include?("/up")
    0.1
  end

  # Off deliberately: with this on, Sentry attaches request headers, cookies,
  # and IP addresses. Rally handles registration data and payment records, so
  # the default is to send as little as possible. Turn on only with a
  # deliberate decision about what ends up in Sentry.
  #
  # The authenticated user's id (and only the id — no email) is attached
  # separately in ApplicationController#set_sentry_user, which is enough to
  # tell "one user hit this 40 times" apart from "40 users hit this once".
  config.send_default_pii = false
end
