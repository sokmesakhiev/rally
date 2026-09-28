# The environment the Playwright end-to-end suite runs against.
#
# Why it exists at all (docs/e2e-testing-design.md, D5): `test` belongs to
# RSpec, and a Playwright run truncating tables would pull the database out
# from under a developer running specs in another terminal. `development`
# belongs to the developer, and destroying their own data is the fastest way
# to make them stop running the suite.
#
# The shape here is **production-like, not test-like**: eager loaded, errors
# handled the way the deployed app handles them, jobs actually executed. A
# suite that runs against a differently-configured app tests an application
# that doesn't ship.
#
# Everything in this file is local-only. Nothing here is ever deployed, and
# `RAILS_ENV=e2e` is not a value any Dockerfile, task definition or workflow
# sets.

# Rails ignores `config.secret_key_base` outside the local environments
# (`development`/`test`) — there it reads ENV["SECRET_KEY_BASE"] or the
# credentials file and raises if neither is present. `e2e` is not local, so
# the assignment further down would silently do nothing on its own. Setting
# the env var here is what actually works; the config assignment stays as
# belt and braces in case a future Rails consults it.
#
# The value is deliberately fixed rather than random: config/initializers/
# active_record_encryption.rb derives the Active Record encryption keys from
# secret_key_base, so a per-boot secret would make an organization's stored
# PayWay key undecryptable after a server restart. It is a publicly-known
# constant in a local-only environment, which is the whole reason it is safe
# to write down — do not copy this pattern into production.
ENV["SECRET_KEY_BASE"] ||= "e2e" * 32

# JWT_SECRET, for the same reason and with one extra wrinkle.
#
# `lib/json_web_token.rb` reads it at *load* time:
#
#     SECRET_KEY = ENV.fetch("JWT_SECRET").presence || Rails.application.secret_key_base
#
# and `ENV.fetch` with no default **raises** when the key is absent, so the
# `|| secret_key_base` fallback only ever fires for a key that is set but
# blank. `config.eager_load = true` below means that line runs during boot,
# which is why an unset JWT_SECRET is a stack trace on `bin/rails server`
# rather than a 500 on the first sign-in.
#
# Development and test never notice, because `dotenv-rails` (Gemfile's
# `:development, :test` group) loads backend/.env for them. This environment
# is the first one to boot without it — so it has to say the value itself.
#
# **Deliberately not "fixing" that fetch to fall back quietly.** Crashing on
# boot is the better behaviour for production: a silent fall back to
# secret_key_base would re-key every issued token and sign out every user on
# the platform, which is a worse Tuesday than a failed deploy.
#
# Fixed rather than random, so tokens minted before a server restart still
# decode — a journey that signs in, restarts nothing, and then finds itself
# logged out would be a confusing way to learn that.
ENV["JWT_SECRET"] ||= "e2e-jwt-secret-not-a-real-key"

Rails.application.configure do
  config.secret_key_base = ENV["SECRET_KEY_BASE"]

  # Load everything at boot, as production does. A missing constant should
  # fail on `bin/rails server`, not inside journey 4 at 3am in the nightly
  # run, where it would read as a flaky test.
  config.eager_load = true
  config.enable_reloading = false

  # `:all` is production's setting — Rails renders an error response rather
  # than letting the exception escape, which is what the frontend has to cope
  # with. `consider_all_requests_local` then puts the real message and
  # backtrace in that response instead of a generic page. Production-shaped
  # behaviour, debuggable content: an e2e failure is hard enough to diagnose
  # without the server hiding what went wrong.
  config.action_dispatch.show_exceptions = :all
  config.consider_all_requests_local = true

  # STDOUT, because Playwright's `webServer` captures it and surfaces it
  # beside the failing test. A log file nobody opens is the same as no log.
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_tags = [ :request_id ]

  # Jobs run for real, in-process, on a thread pool.
  #
  # Production uses Solid Queue in a separate ECS service, and that gem is in
  # the `:production` bundle group, so it is not even loaded here. `:async` is
  # the closest available thing and it is honest about what it is: **jobs
  # execute, but nothing survives a restart and nothing retries.** That is
  # enough for the journeys in scope — a waitlist promotion or a payment
  # notification has to actually happen for the test to mean anything, and
  # none of them assert retry behaviour. If a journey ever does need retries,
  # that is the day this becomes a real worker rather than the day someone
  # adds a sleep.
  config.active_job.queue_adapter = :async

  # Solid Cache is production-group too. rack-attack's counters live here —
  # see the note in the reset endpoint about clearing them between journeys.
  config.cache_store = :memory_store

  # Its own Active Storage root (config/storage.yml), NOT :local. `:local`
  # writes to backend/storage/, which is the developer's own development
  # uploads — the reset endpoint empties this directory, and emptying
  # somebody's development files would be the same mistake D5 exists to
  # avoid.
  config.active_storage.service = :e2e

  # Accumulates in ActionMailer::Base.deliveries and goes nowhere. Asserting
  # on mail from Playwright is Open Question 2 in the design doc; switching
  # this to `:file` is the change that would enable it.
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.default_url_options = {
    host: ENV.fetch("FRONTEND_URL", "http://localhost:8080")
  }

  # The SPA is served from :8080 and this API answers on :3000, so every
  # WebSocket connection is cross-origin and ActionCable's forgery protection
  # would refuse it — the same failure production hits when
  # ACTION_CABLE_ALLOWED_ORIGINS is unset, and it looks like nothing but
  # "Request origin not allowed" in the log. Nothing in the v1 journeys opens
  # a socket (support chat is out of scope), so this is here to stop a future
  # journey losing an afternoon to a solved problem.
  config.action_cable.allowed_request_origins = [
    %r{\Ahttp://(localhost|127\.0\.0\.1):\d+\z}
  ]

  config.active_support.deprecation = :stderr
  config.active_support.report_deprecations = false

  # Local HTTP everywhere: Vite serves the SPA over http://localhost:8080 and
  # Rails answers on http://localhost:3000. Forcing SSL would redirect every
  # request in the suite.
  config.force_ssl = false
  config.assume_ssl = false

  config.action_controller.raise_on_missing_callback_actions = true
  config.i18n.fallbacks = true
end
