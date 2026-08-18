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
    rescue JWT::DecodeError, ActiveRecord::RecordNotFound
      nil # garbage/stale token on an endpoint that doesn't require one — proceed anonymously
    end
  end

  # For Api::V1::Admin controllers — see Api::V1::Admin::BaseController.
  def require_admin!
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

    Sentry.set_user(id: @current_user.id)
  end

  def current_user
    @current_user
  end

  def extract_token
    header = request.headers["Authorization"]
    header&.split(" ")&.last
  end
end
