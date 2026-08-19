# frozen_string_literal: true

# Rate limiting for the public API.
#
# Two things worth knowing about how this is wired here:
#
# 1. **Cache store.** Rack::Attack needs a shared counter store, otherwise
#    each Puma worker throttles independently and the effective limit is
#    (limit × worker count). It defaults to Rails.cache, which in production
#    is Solid Cache (Postgres-backed, shared across every task) — correct.
#    In development/test the cache store is :null_store / :memory_store, so
#    throttling would silently never trigger; we point it at an explicit
#    MemoryStore below so the behavior is at least testable locally.
#
# 2. **Client identity.** `req.ip` behind an ALB is only trustworthy because
#    Rails' ActionDispatch::RemoteIp middleware resolves X-Forwarded-For for
#    us, and the ALB overwrites the rightmost entry. Don't switch these to
#    read X-Forwarded-For directly — a client can forge that header, which
#    would let an attacker trivially rotate their way around every limit.
#
# Limits are deliberately generous: the goal is blunting credential stuffing
# and scripted abuse, not policing normal use. A real person signing in a
# few times after typos should never see a 429.
class Rack::Attack
  # See note 1 above.
  unless Rails.env.production?
    self.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  # Off by default in the test env, on everywhere else. Without this the
  # existing request specs break: auth_spec.rb alone posts to
  # /api/v1/auth/signin about six times, all from 127.0.0.1 within a second
  # or two, which trips the signin burst limit and turns unrelated examples
  # into spurious 429s. Specs that actually want to assert throttling opt in
  # via the `:rack_attack` metadata tag — see spec/support/rack_attack.rb.
  self.enabled = !Rails.env.test?

  ### Allow-listing ###########################################################

  # ABA PayWay's payment webhook. Throttling this would mean dropping payment
  # confirmations under load — exactly when we least want to. It's already
  # safe to hammer: the handler only does a DB lookup and enqueues a job, and
  # it never trusts the payload (ProcessAbaPaywayWebhookJob re-verifies with
  # ABA server-to-server), so an attacker flooding it achieves nothing beyond
  # queue noise. Kept as an explicit allow rather than relying on it falling
  # under some generous limit.
  safelist("aba payway webhook") do |req|
    req.path == "/api/v1/webhooks/aba_payway" && req.post?
  end

  # Health check — the ALB target group polls this constantly.
  safelist("health check") do |req|
    req.path == "/up"
  end

  ### Throttles ###############################################################

  # Blanket per-IP limit, as a backstop for endpoints not called out below.
  throttle("req/ip", limit: 300, period: 5.minutes, &:ip)

  # ── Credential stuffing surface ──
  #
  # Sign-in gets two limits at different timescales, which is the standard
  # pattern: the short one stops a burst, the long one stops a slow grind
  # that would stay under the short limit forever (6/20s = 1,080/hour).
  throttle("signin/ip/burst", limit: 6, period: 20.seconds) do |req|
    req.ip if req.post? && req.path == "/api/v1/auth/signin"
  end

  throttle("signin/ip/hourly", limit: 60, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/api/v1/auth/signin"
  end

  # Also throttle per email address, not just per IP — a distributed attack
  # rotating IPs against one account slips past every IP-based limit. Keyed on
  # the normalized email so casing/whitespace variants share a counter.
  throttle("signin/email", limit: 12, period: 20.minutes) do |req|
    if req.post? && req.path == "/api/v1/auth/signin"
      email_from(req)
    end
  end

  # Google sign-in hits our ID-token verification path, which does a (cached)
  # outbound fetch of Google's signing keys — worth a limit of its own.
  throttle("auth_google/ip", limit: 20, period: 5.minutes) do |req|
    req.ip if req.post? && req.path == "/api/v1/auth/google"
  end

  # ── Account creation ──
  throttle("signup/ip", limit: 10, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/api/v1/auth/signup"
  end

  # ── Email-sending endpoints ──
  #
  # These are the endpoints where abuse costs real money and can get our SES
  # sending reputation damaged (each request sends mail to an address the
  # requester chose), so they're the tightest limits here. Password reset is
  # additionally throttled per email so one address can't be mail-bombed from
  # many IPs.
  throttle("password_reset/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/api/v1/password_resets"
  end

  throttle("password_reset/email", limit: 5, period: 1.hour) do |req|
    email_from(req) if req.post? && req.path == "/api/v1/password_resets"
  end

  throttle("email_verification/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/api/v1/email_verifications"
  end

  # AuthController#change_email requires current_password, but that's not
  # much of a wall — any signed-in account (including one the attacker just
  # signed up themselves) can call this, and each call sends
  # UserMailer#email_verification to whatever new_email it's given. No
  # dedicated limit here meant this could only ride the 300/5min blanket
  # req/ip backstop below — three orders of magnitude looser than every
  # other email-sending endpoint on this page. Keyed on IP (same reasoning
  # as registrations/ip — a token isn't a trustworthy identity here) and
  # additionally on the target address, so rotating accounts/IPs can't be
  # used to mail-bomb one victim.
  throttle("auth_email_change/ip", limit: 10, period: 1.hour) do |req|
    req.ip if req.patch? && req.path == "/api/v1/auth/email"
  end

  throttle("auth_email_change/target_email", limit: 5, period: 1.hour) do |req|
    new_email_from(req) if req.patch? && req.path == "/api/v1/auth/email"
  end

  # ── Write-heavy authenticated endpoints ──
  #
  # Registration creation and uploads both cost us storage/DB work. Keyed on
  # IP rather than user id: an attacker with a valid token can't be trusted to
  # keep using one account, and unauthenticated requests have no user at all.
  throttle("registrations/ip", limit: 20, period: 10.minutes) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/api/v1/events/[^/]+/registrations\z})
  end

  throttle("uploads/ip", limit: 30, period: 10.minutes) do |req|
    req.ip if req.post? && req.path == "/api/v1/uploads"
  end

  # ── Guest checkout (Registrations::GuestCheckout) ──
  #
  # An unauthenticated POST to the registrations endpoint above isn't just a
  # write — it creates a brand-new User row, and when a real email is given,
  # RegistrationMailer#confirmation sends a "you're registered" email to
  # whatever address the requester typed, no proof of ownership required.
  # That's exactly the "costs real money / damages SES reputation" shape as
  # signup/password_reset above, so it needs their tier of limit, not the
  # generic 20/10min registrations/ip one above (≈120/hour — plenty of room
  # to mail-bomb a stranger). No Authorization header is the signal this
  # middleware layer has for "this is the guest path, not a signed-in
  # participant" — the controller resolves the real current_user later, but
  # by then it's too late to throttle. Both throttles apply in addition to
  # registrations/ip, not instead of it.
  throttle("guest_registrations/ip", limit: 10, period: 1.hour) do |req|
    if req.post? && guest_registration_path?(req)
      req.ip
    end
  end

  # Per-target-email, so an attacker can't dodge the IP limit by rotating
  # IPs while spamming one victim's inbox across many different events.
  throttle("guest_registrations/email", limit: 5, period: 1.hour) do |req|
    if req.post? && guest_registration_path?(req)
      guest_email_from(req)
    end
  end

  ### Response ################################################################

  # JSON, not Rack::Attack's default text/plain body — every other error in
  # this API is JSON, and api-client.ts reads `json.error`. Retry-After lets a
  # well-behaved client back off correctly instead of retrying immediately.
  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = (match_data[:period] || 60).to_i

    body = {
      error: "Too many requests. Please wait a moment and try again.",
      code: "rate_limited"
    }.to_json

    [
      429,
      {
        "Content-Type" => "application/json",
        "Retry-After" => retry_after.to_s
      },
      [ body ]
    ]
  end

  # Reads the email out of a JSON or form-encoded body without disturbing the
  # request for downstream middleware (Rack caches the rewound body), and
  # normalizes it with the same `downcase.strip` User applies in its
  # before_validation hook, so the throttle key matches the account that
  # would actually be looked up.
  def self.email_from(req)
    body = req.body.read
    req.body.rewind

    email =
      if req.media_type == "application/json"
        JSON.parse(body)["email"]
      else
        Rack::Utils.parse_nested_query(body)["email"]
      end

    email.to_s.downcase.strip.presence
  rescue JSON::ParserError
    nil
  end

  def self.guest_registration_path?(req)
    # No Authorization header is the only signal available at this layer —
    # see the guest_registrations throttles' comment above.
    req.path.match?(%r{\A/api/v1/events/[^/]+/registrations\z}) &&
      req.get_header("HTTP_AUTHORIZATION").blank?
  end

  # Same shape as email_from, but the registration create endpoint nests it
  # one level down: { guest: { email:, phone:, name: } } — see
  # RegistrationCreateRequestSchema / registrationsApi.create.
  def self.guest_email_from(req)
    body = req.body.read
    req.body.rewind

    email =
      if req.media_type == "application/json"
        JSON.parse(body).dig("guest", "email")
      else
        Rack::Utils.parse_nested_query(body).dig("guest", "email")
      end

    email.to_s.downcase.strip.presence
  rescue JSON::ParserError
    nil
  end

  # AuthController#change_email's target field is top-level (`new_email`),
  # not `email` — reuses email_from's parsing shape under a name that
  # matches what's actually being read.
  def self.new_email_from(req)
    body = req.body.read
    req.body.rewind

    email =
      if req.media_type == "application/json"
        JSON.parse(body)["new_email"]
      else
        Rack::Utils.parse_nested_query(body)["new_email"]
      end

    email.to_s.downcase.strip.presence
  rescue JSON::ParserError
    nil
  end
end

# Log throttled requests so a spike is visible in CloudWatch rather than
# silently dropping traffic. Deliberately not logging the request body.
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn(
    "[rack-attack] throttled #{req.env['rack.attack.matched']} " \
    "ip=#{req.ip} path=#{req.request_method} #{req.path}"
  )
end
