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

  # Event team invitations (Api::V1::EventInvitationsController#create) are
  # the same shape as the email-sending endpoints above — each call sends a
  # real message to an address the requester (the event's owner/manager)
  # chooses — but were missed when that endpoint originally shipped. Three
  # limits, same reasoning as elsewhere in this file: per IP as a backstop,
  # per inviting account (keyed on the JWT, same as "uploads/user" below —
  # an authenticated attacker has exactly one identity, so IP alone is
  # trivially dodged with a VPN), and per *target* email so one address
  # can't be mail-bombed by inviting/revoking/reinviting on one event, or by
  # being invited to several events the same owner controls (same reasoning
  # as "password_reset/email" above). The looser 20/10min limits (vs.
  # password reset's 5/hour) leave room for an organizer legitimately
  # building out a large team in one sitting; the per-email limit stays
  # tight since no real recipient needs more than a couple of invites an hour.
  throttle("invitations/ip", limit: 20, period: 10.minutes) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/api/v1/events/[^/]+/invitations\z})
  end

  throttle("invitations/user", limit: 20, period: 10.minutes) do |req|
    if req.post? && req.path.match?(%r{\A/api/v1/events/[^/]+/invitations\z})
      user_id_from(req)
    end
  end

  throttle("invitations/email", limit: 5, period: 1.hour) do |req|
    if req.post? && req.path.match?(%r{\A/api/v1/events/[^/]+/invitations\z})
      email_from(req)
    end
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

  # Also throttle uploads per account, not just per IP (see issue #282) —
  # unlike the anonymous auth endpoints above, a signed-in attacker already
  # has exactly one identity that's cheaper to keep than to burn, so an
  # IP-only limit is trivially dodged with a VPN/proxy while reusing the same
  # token. Keyed on the JWT's user_id rather than a live User lookup: a
  # forged id is impossible without SECRET_KEY (see JsonWebToken), so it's
  # trustworthy enough for a rate-limit counter even though it's never used
  # here for actual authorization.
  throttle("uploads/user", limit: 30, period: 10.minutes) do |req|
    user_id_from(req) if req.post? && req.path == "/api/v1/uploads"
  end

  # ── Payments (now reachable without a session) ──
  #
  # Api::V1::PaymentsController accepts an anonymous request authorized by a
  # matching email/phone instead of a login (see GuestCheckout) — that's an
  # intentional trade-off, not a bug, but it does mean this endpoint is a
  # softer target than a normal authenticated one, so it gets its own limit
  # rather than relying on the generic req/ip backstop. Registration and
  # payment ids are UUIDs (not guessable on their own), but this is cheap
  # defense in depth regardless. Covers both POST .../payments and
  # GET /payments/:id under one counter.
  throttle("payments/ip", limit: 30, period: 10.minutes) do |req|
    req.ip if req.path.match?(%r{\A/api/v1/(registrations/[^/]+/payments|payments/[^/]+)\z})
  end

  # ── WebSocket connection tickets ──
  #
  # Legitimate use is roughly one call per connection: on page load, and again
  # on each reconnect. Reconnects cluster (every deploy severs every socket at
  # once, and ActionCable retries with backoff), so the limit has to absorb a
  # burst without permitting a loop — 30/5min is several times the worst honest
  # case and still far below what would matter.
  #
  # Worth its own counter despite the generic "req/ip" backstop (300/5min):
  # every call writes an entry into the shared Solid Cache, so this is a way to
  # churn a resource the whole platform depends on, and the 300 budget is meant
  # for ordinary browsing rather than one endpoint.
  #
  # Keyed per user, not per IP: a caller must already be authenticated to get
  # here at all, so there's an identity to key on — and unlike an IP, it isn't
  # shed by switching networks. Same reasoning as "uploads/user" above; falls
  # through to "req/ip" for a request with no usable token, which
  # authenticate_user! rejects anyway.
  throttle("cable_ticket/user", limit: 30, period: 5.minutes) do |req|
    user_id_from(req) if req.post? && req.path == "/api/v1/cable/ticket"
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

  # Decodes the same Bearer JWT ApplicationController#extract_token reads,
  # for the "uploads/user" throttle above. Deliberately doesn't hit the
  # database (no User.find, no suspended/discarded checks) — those only
  # matter for authorization, and this is purely a rate-limit key. A
  # missing/garbage/expired token just means no per-user key, which is fine:
  # the request still falls under the per-IP throttle above, and an
  # unauthenticated request gets 401'd by the controller regardless.
  def self.user_id_from(req)
    token = req.env["HTTP_AUTHORIZATION"]&.split(" ")&.last
    return nil unless token

    JsonWebToken.decode(token)[:user_id]
  rescue JWT::DecodeError
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
