class ApplicationController < ActionController::API
  before_action :set_default_format

  private

  def set_default_format
    request.format = :json
  end

  def authenticate_user!
    token = extract_token
    unless token
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    begin
      payload = JsonWebToken.decode(token)
      user = User.find(payload[:user_id])

      # Enforced here, on every authenticated request, rather than only at
      # sign-in: tokens are stateless and valid for 30 days, so checking only
      # at sign-in would leave an already-issued token working for weeks after
      # a suspension. 403 rather than 401 — the credentials are valid, the
      # account just isn't permitted to act.
      if user.suspended?
        render json: { error: "This account has been suspended.", code: "account_suspended" },
               status: :forbidden
        return
      end

      # Same stateless-token reasoning as the suspended check above — a
      # 30-day-old token for a since-deleted (anonymized, see
      # User#discard!) account must stop working immediately, not linger
      # until it expires. 401, not 403: as far as this token's owner is
      # concerned, that identity no longer exists.
      if user.discarded?
        render json: { error: "This account no longer exists.", code: "account_deleted" },
               status: :unauthorized
        return
      end

      @current_user = user
      set_sentry_user
      adopt_impersonation!(payload)
    rescue JWT::DecodeError, ActiveRecord::RecordNotFound
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  # Same token/suspension/deletion checks as authenticate_user! above, but
  # never renders an error just because a token is missing or unparseable —
  # for endpoints (Api::V1::RegistrationsController#create's guest checkout)
  # that serve both signed-in users and anonymous guests. @current_user
  # simply stays nil for an anonymous request, same as if this method were
  # never called. A *valid* token for a suspended/deleted account still gets
  # the real error, though — that's a deliberate account-status block, not
  # "you're simply not signed in", and the caller shouldn't silently treat
  # it as guest checkout.
  def authenticate_user_optional!
    token = extract_token
    return unless token

    begin
      payload = JsonWebToken.decode(token)
      user = User.find(payload[:user_id])

      if user.suspended?
        render json: { error: "This account has been suspended.", code: "account_suspended" },
               status: :forbidden
        return
      end

      if user.discarded?
        render json: { error: "This account no longer exists.", code: "account_deleted" },
               status: :unauthorized
        return
      end

      @current_user = user
      set_sentry_user
      # strict: false — this method never renders for a bad token, so a dead
      # impersonation session must leave the caller anonymous rather than 401.
      # A *live* session on a write is still refused; see #adopt_impersonation!.
      adopt_impersonation!(payload, strict: false)
    rescue JWT::DecodeError, ActiveRecord::RecordNotFound
      nil # garbage/stale token on an endpoint that doesn't require one — proceed anonymously
    end
  end

  # For genuinely public endpoints (no sign-in required at all, e.g.
  # Api::V1::EventsController#show) that still want to know *who's asking*
  # when a token happens to be present — so they can tag a response with
  # "your role on this event", say — without that ever turning into a block.
  #
  # This is deliberately NOT authenticate_user_optional! with the error
  # branches removed by accident — it's a different contract. That method
  # exists for guest checkout, where "signed in but suspended" is a real,
  # intentional account-status block on an action (registering). A public
  # page was never gated on sign-in status in the first place, so a
  # suspended/deleted account's stale token should produce exactly what an
  # anonymous visitor gets, not a 403/401 for a page they never had to be
  # logged in to see. current_user simply stays nil in every failure case —
  # missing token, garbage token, or a valid token for an account that can
  # no longer act — with nothing ever rendered here.
  def identify_current_user!
    token = extract_token
    return unless token

    payload = JsonWebToken.decode(token)
    user = User.find(payload[:user_id])
    return if user.suspended? || user.discarded?

    @current_user = user
    set_sentry_user
    # strict: false, same as authenticate_user_optional! — this one's whole
    # contract is that current_user simply stays nil in every failure case.
    adopt_impersonation!(payload, strict: false)
  rescue JWT::DecodeError, ActiveRecord::RecordNotFound
    nil # garbage/stale/expired token on a page that was never gated on auth
  end

  # ── Impersonation ───────────────────────────────────────────────────────────
  # See docs/impersonation-design.md. Everything below runs only when a token
  # carries `imp`, so an ordinary request pays for none of it.

  # Called from all three token readers above — they are the only places in the
  # app that decode a JWT, which is what makes this the complete set of entry
  # points.
  #
  # `strict:` is the difference between the reader that *requires* a signed-in
  # user and the two that merely notice one. `authenticate_user_optional!` and
  # `identify_current_user!` both promise, at length, never to render — a
  # public event page and guest checkout were never gated on sign-in, so a
  # stale token must produce what an anonymous visitor gets. An earlier version
  # of this method rendered a 401 from inside them, which turned a forgotten
  # impersonation key in localStorage into an error page on routes that don't
  # need auth at all.
  #
  # What does *not* soften is the write refusal. A dead session degrades to
  # anonymous; a **live** one on a non-GET is still refused in both modes,
  # because proceeding anonymously there would let an impersonated session
  # perform a guest-checkout write — read-only failing open in exactly the
  # place it matters most.
  def adopt_impersonation!(payload, strict: true)
    return true unless payload[:imp]

    session = ImpersonationSession.find_by(id: payload[:sid])

    unless adoptable?(session, payload)
      @current_user = nil unless strict
      return false unless strict

      # The token is intact and correctly signed; the *session* is over. 401
      # with its own code so the frontend drops the impersonation key and puts
      # the admin back in their own account rather than logging anyone out.
      render json: { error: "This impersonation session has ended.",
                     code: "impersonation_ended" }, status: :unauthorized
      return false
    end

    @impersonation = session
    set_sentry_user
    log_impersonated_request

    # Deliberately checked *here*, at adoption, rather than as its own
    # before_action. A separate filter would have to be ordered after
    # authentication in every controller that authenticates, and the one that
    # forgot would be a silent hole. This runs inside the thing that discovers
    # the request is impersonated at all, so it cannot be skipped.
    allow_impersonated_request?
  end

  # Three questions, and the third is the one that was missing.
  #
  #   1. Does the row still permit this? (`#live?` — ended, revoked, expired.)
  #   2. Is it for the account the token names? (A token whose `user_id` and
  #      `sid` disagree is tampering, not a stale session.)
  #   3. **Is the actor still staff?** `subscribed` runs once and a socket lives
  #      for hours — the same shape as this: the row is checked every request
  #      but nothing re-read the *admin*, so demoting, suspending or deleting a
  #      staff account left their open session working for the rest of its 30
  #      minutes, i.e. straight through an offboarding. `SupportInboxChannel`
  #      learned this already (`ACCESS_RECHECK`); this is the HTTP counterpart,
  #      and it's free here because the request is already loading the row.
  #
  # `payload[:act]` is compared against the row rather than trusted: the token
  # is signed, so they can't disagree without a bug, and pinning it means a
  # future change to the payload can't silently start authorising against a
  # different admin than the one the audit trail names.
  def adoptable?(session, payload)
    return false unless session&.live?
    return false unless session.user_id == @current_user&.id
    return false unless payload[:act] == session.admin_id

    actor = session.admin
    actor.admin? && !actor.suspended? && !actor.discarded?
  end

  # **Read-only, enforced by HTTP verb, default-deny.** The rule is the verb and
  # not a list of protected endpoints, because a controller written next year
  # is then covered on the day it's written by someone who has never read the
  # design doc. An allowlist of "safe" endpoints has exactly the failure mode
  # the manage-event tab bar's TAB_GRID_CLASSES had: a hand-maintained list
  # that silently stops matching reality.
  #
  # This is what blocks password changes, email changes, account deletion and
  # admin promotion — all of them writes, none of them needing a rule of their
  # own. It's also why an impersonated session gets no WebSocket:
  # POST /cable/ticket is a write by this rule, which is the right answer
  # anyway, since staff are the other side of support chat.
  def allow_impersonated_request?
    return true if request.get? || request.head?

    render json: {
      error: "This is a read-only support session. Sign in as yourself to make changes.",
      code: "impersonation_read_only"
    }, status: :forbidden
    false
  end

  # One line per impersonated request, to the log aggregator — never a row per
  # request in Postgres. An agent clicking through an account would out-produce
  # every other audit source combined, the same reason the support console
  # doesn't audit `read`. The two `admin_actions` rows (start and end) are the
  # durable record; this is what answers "what did they actually look at"
  # during an investigation, for as long as logs are kept.
  def log_impersonated_request
    Rails.logger.info(
      "[impersonation] actor=#{@impersonation.admin_id} subject=#{@impersonation.user_id} " \
      "sid=#{@impersonation.id} #{request.request_method} #{request.path}"
    )
  end

  def impersonating? = @impersonation.present?

  # The one thing read-only does *not* cover: a GET that returns someone's
  # payment credentials. Read-only protects the user's data from staff; it
  # does nothing about the user's secrets, which are readable by definition.
  #
  # `payway_merchant_id` and `payway_api_key_masked` are therefore nulled in a
  # support session — the merchant id isn't masked at all, and neither belongs
  # in a support view. **The booleans stay**: "is my payment setup complete"
  # is one of the most common things support is asked, `payway_configured?`
  # answers it, and a flag saying *whether* a credential exists is not the
  # credential. Blanket-403ing the whole endpoint would have hidden the answer
  # along with the secret and made the feature useless for its main job.
  #
  # `payway_hidden` tells the frontend to render "hidden in support session"
  # rather than the empty state for "not set up yet", which would be a lie.
  #
  # Both the profile and the organization payload go through here, so they
  # cannot drift — the two used to carry byte-identical PayWay blocks.
  def payway_identity_fields(organization)
    if impersonating?
      { payway_merchant_id: nil, payway_api_key_masked: nil, payway_hidden: true }
    else
      {
        payway_merchant_id: organization&.payway_merchant_id,
        payway_api_key_masked: organization&.payway_api_key_masked,
        payway_hidden: false
      }
    end
  end

  # For Api::V1::Admin controllers — see Api::V1::Admin::BaseController.
  def require_admin!
    # Checked *before* admin?, not after. Without this, impersonating an admin
    # would launder one staff member's actions through another's identity and
    # the audit trail would name the wrong person. With it, impersonating an
    # admin is pointless rather than forbidden: the console 404s exactly as it
    # does for everyone else.
    #
    # Starting a session against an admin is additionally refused at the
    # endpoint, so the intent shows up in the audit log rather than being
    # inferred from a 404. Two mechanisms, deliberately — this is the privilege
    # escalation, so if the endpoint check is ever relaxed by someone who
    # thinks staff should be able to help each other, this still holds.
    return head :not_found if impersonating?
    return if current_user&.admin?

    # 404, not 403: an admin surface shouldn't confirm its own existence to a
    # non-admin who goes looking for it.
    render json: { error: "Not found" }, status: :not_found
  end

  # Attaches the current user's id to any Sentry event raised later in this
  # request. Id only, never email — Sentry runs with send_default_pii = false
  # (see config/initializers/sentry.rb) and this shouldn't quietly undo that.
  # No-ops when Sentry isn't initialized (i.e. whenever SENTRY_DSN is unset,
  # which is every local and CI run), so this needs no test-env guard.
  def set_sentry_user
    return unless defined?(Sentry) && Sentry.initialized?

    # `id` stays the account the request is acting as, so an error raised
    # during impersonation groups with that account's other errors — which is
    # the point of looking. `impersonated_by` says who was really driving, so
    # nobody chases an organizer about an exception staff triggered.
    Sentry.set_user({ id: @current_user.id }.tap do |attrs|
      attrs[:impersonated_by] = @impersonation.admin_id if @impersonation
    end)
  end

  def current_user
    @current_user
  end

  def extract_token
    header = request.headers["Authorization"]
    header&.split(" ")&.last
  end
end
