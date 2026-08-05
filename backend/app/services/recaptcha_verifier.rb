# frozen_string_literal: true

require "net/http"
require "json"

# Verifies Google reCAPTCHA v3 tokens server-side (AuthController#signup).
#
# Gated behind RECAPTCHA_SECRET_KEY: when unset (local development, CI,
# request specs), #verify short-circuits to a passing result so the feature
# never blocks signup for anyone who hasn't set up a Google reCAPTCHA site —
# same "leave the feature disabled until configured" philosophy as
# GOOGLE_CLIENT_ID (see AuthController#google) and VITE_GOOGLE_MAPS_API_KEY
# on the frontend. The matching frontend gate is VITE_RECAPTCHA_SITE_KEY —
# see src/lib/recaptcha.ts.
#
# reCAPTCHA v3 has no checkbox/challenge UI and no explicit pass/fail —
# Google scores every request 0.0 (likely a bot) to 1.0 (likely human) and
# it's up to the site to pick a threshold. 0.5 is Google's own suggested
# starting point.
#
# Docs: https://developers.google.com/recaptcha/docs/v3
module RecaptchaVerifier
  SITEVERIFY_URL = "https://www.googleapis.com/recaptcha/api/siteverify"
  MIN_SCORE = 0.5

  Result = Struct.new(:success?, :score, :reason, keyword_init: true)

  class RequestError < StandardError; end

  class << self
    def configured?
      secret_key.present?
    end

    # token: the token minted client-side by grecaptcha.execute(siteKey,
    # { action }) — see src/lib/recaptcha.ts.
    # action: the action name the caller expects, e.g. "signup" — must match
    # what Google recorded when the token was minted, otherwise a token
    # captured from a different form could be replayed here.
    def verify(token, action:, remote_ip: nil)
      return Result.new(success?: true, score: nil, reason: "unconfigured") unless configured?
      return Result.new(success?: false, score: nil, reason: "missing_token") if token.blank?

      response = post_siteverify(token, remote_ip)

      unless response["success"]
        return Result.new(success?: false, score: nil, reason: Array(response["error-codes"]).join(",").presence || "unknown")
      end

      if response["action"] != action
        return Result.new(success?: false, score: response["score"], reason: "action_mismatch")
      end

      score = response["score"].to_f
      return Result.new(success?: false, score: score, reason: "low_score") if score < MIN_SCORE

      Result.new(success?: true, score: score, reason: nil)
    rescue RequestError => e
      # Fail closed on our own request errors (network hiccup, timeout, bad
      # JSON from Google) rather than silently letting signup through —
      # blocked signups can retry; letting a request error through defeats
      # the point of verifying at all.
      Result.new(success?: false, score: nil, reason: e.message)
    end

    private

    def secret_key
      ENV["RECAPTCHA_SECRET_KEY"].presence
    end

    def post_siteverify(token, remote_ip)
      uri = URI(SITEVERIFY_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 5

      params = { secret: secret_key, response: token }
      params[:remoteip] = remote_ip if remote_ip.present?

      request = Net::HTTP::Post.new(uri)
      request.set_form_data(params)

      http_response = http.request(request)
      JSON.parse(http_response.body)
    rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED, SocketError => e
      raise RequestError, "reCAPTCHA verification request failed: #{e.message}"
    end
  end
end
