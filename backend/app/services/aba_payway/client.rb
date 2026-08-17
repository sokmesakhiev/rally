require "net/http"
require "openssl"
require "base64"
require "json"

# Thin client for the ABA PayWay payment gateway (KHQR).
#
# Docs: https://developer.payway.com.kh
#
# Default credentials/base_url come from config/payway.yml — one section per
# environment, same pattern as config/database.yml. merchant_id / api_key
# still ultimately come from ENV (the yml just reads them via ERB), but
# base_url is now pinned explicitly per environment there, so production can
# never silently fall back to the sandbox URL just because an env var was
# left unset.
module AbaPayway
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RequestError < Error; end

  class Client
    GENERATE_QR_PATH = "/api/payment-gateway/v1/payments/generate-qr"
    CHECK_TRANSACTION_PATH = "/api/payment-gateway/v1/payments/check-transaction-2"
    # Note: this is a different base path than the other two (/payment-gateway/
    # vs /merchant-portal/merchant-access/) — that's ABA's own API layout, not
    # a typo. See https://developer.payway.com.kh/refund-api-14530821e0.
    REFUND_PATH = "/api/merchant-portal/merchant-access/online-transaction/refund"

    # RSA public key chunk size for #refund's merchant_auth encryption — see
    # that method. 117 bytes is what ABA's own PHP sample uses (PKCS#1 v1.5
    # padding overhead is 11 bytes, so this matches a 1024-bit/128-byte RSA
    # key: 128 - 11 = 117). If ABA ever issues a larger key this would need
    # to change, but there's no way to detect that up front — it's baked
    # into their sample code, not derived from the key itself.
    REFUND_ENCRYPTION_CHUNK_SIZE = 117

    def initialize(merchant_id: self.class.config.merchant_id,
                   api_key: self.class.config.api_key,
                   base_url: self.class.config.base_url,
                   rsa_public_key: self.class.config.rsa_public_key)
      @merchant_id = merchant_id
      @api_key = api_key
      @base_url = base_url.to_s.chomp("/")
      @rsa_public_key = rsa_public_key
    end

    class << self
      # config/payway.yml, keyed by environment (same pattern as
      # config/database.yml). Re-read on every call rather than cached once
      # at boot, so ENV overrides take effect immediately without a server
      # restart, and so tests can swap credentials per example the same way
      # they always have.
      def config
        Rails.application.config_for(:payway)
      end

      # Builds a client for a registration payment (attendee → organizer) on
      # the given event. Uses the event creator's own PayWay credentials when
      # they've connected one via their profile (Profile#payway_configured?),
      # so the money lands directly in the organizer's PayWay account;
      # otherwise falls back to the platform's default credentials
      # (config/payway.yml).
      #
      # Organizer "pay to publish" charges (EventPlanPayment — organizer →
      # Rally) must never use this; they should always use `Client.new` with
      # no args so proceeds go to Rally's own account.
      def for_event(event)
        profile = event.creator&.profile
        if profile&.payway_configured?
          # payway_rsa_public_key may still be nil here (it's optional even
          # once payway_configured? is true — see Profile#payway_refund_configured?);
          # #refund raises a clear ConfigurationError if it's actually needed
          # and missing, rather than silently falling back to Rally's own key
          # (which would send the organizer's tran_id to the platform's RSA
          # key — meaningless, since ABA ties merchant_auth's encryption to
          # whichever merchant_id/api_key pair is presented).
          new(merchant_id: profile.payway_merchant_id, api_key: profile.payway_api_key,
              rsa_public_key: profile.payway_rsa_public_key)
        else
          new
        end
      end
    end

    # Generates a dynamic ABA KHQR code for a purchase.
    #
    # Returns a hash with the parsed PayWay response (qrString, qrImage,
    # abapay_deeplink, app_store, play_store, status).
    def generate_qr(tran_id:, amount_cents:, currency:, lifetime_minutes: 15,
                     first_name: nil, last_name: nil, email: nil, phone: nil,
                     callback_url: nil, qr_image_template: "template3_color")
      ensure_configured!

      req_time = format_time(Time.now.utc)
      amount = format_amount(amount_cents, currency)
      items = nil
      return_deeplink = nil
      custom_fields = nil
      return_params = nil
      payout = nil
      encoded_callback_url = callback_url.present? ? Base64.strict_encode64(callback_url) : nil
      purchase_type = "purchase"
      payment_option = "abapay_khqr"

      hash = sign(
        req_time, @merchant_id, tran_id, amount, items, first_name, last_name, email, phone,
        purchase_type, payment_option, encoded_callback_url, return_deeplink, currency.to_s.upcase,
        custom_fields, return_params, payout, lifetime_minutes, qr_image_template
      )

      body = {
        req_time: req_time,
        merchant_id: @merchant_id,
        tran_id: tran_id,
        amount: amount,
        currency: currency.to_s.upcase,
        payment_option: payment_option,
        purchase_type: purchase_type,
        first_name: first_name,
        last_name: last_name,
        email: email,
        phone: phone,
        items: items,
        callback_url: encoded_callback_url,
        return_deeplink: return_deeplink,
        custom_fields: custom_fields,
        return_params: return_params,
        payout: payout,
        lifetime: lifetime_minutes,
        qr_image_template: qr_image_template,
        hash: hash
      }.compact

      post_json(GENERATE_QR_PATH, body)
    end

    # Looks up the current status of a transaction created in the last 7 days.
    def check_transaction(tran_id:)
      ensure_configured!

      req_time = format_time(Time.now.utc)
      hash = sign(req_time, @merchant_id, tran_id)

      post_json(CHECK_TRANSACTION_PATH, {
        req_time: req_time,
        merchant_id: @merchant_id,
        tran_id: tran_id,
        hash: hash
      })
    end

    # Issues a full or partial refund against a COMPLETED (our "approved")
    # transaction, within 30 days of its creation — both constraints are
    # enforced by ABA, not here; a violation comes back as a normal
    # non-"00" status response (e.g. PTL37/PTL57/PTL58), not an exception,
    # same as generate_qr's decline path — see
    # https://developer.payway.com.kh/refund-api-14530821e0.
    #
    # Unlike generate_qr/check_transaction, this needs an RSA public key
    # (provided by ABA Bank, separate from merchant_id/api_key) to encrypt
    # merchant_auth — see #ensure_refund_configured!.
    def refund(tran_id:, amount_cents:, currency:)
      ensure_refund_configured!

      req_time = format_time(Time.now.utc)
      amount = format_amount(amount_cents, currency)
      merchant_auth = build_merchant_auth(tran_id: tran_id, amount: amount)
      hash = sign(req_time, @merchant_id, merchant_auth)

      post_json(REFUND_PATH, {
        request_time: req_time,
        merchant_id: @merchant_id,
        merchant_auth: merchant_auth,
        hash: hash
      })
    end

    private

    def ensure_configured!
      return if @merchant_id.present? && @api_key.present?
      raise ConfigurationError,
        "ABA PayWay merchant_id / api_key are not configured — set ABA_PAYWAY_MERCHANT_ID / " \
        "ABA_PAYWAY_API_KEY (read by config/payway.yml)"
    end

    def ensure_refund_configured!
      ensure_configured!
      return if @rsa_public_key.present?
      raise ConfigurationError,
        "ABA PayWay rsa_public_key is not configured — set ABA_PAYWAY_RSA_PUBLIC_KEY (read by " \
        "config/payway.yml), or the organizer's own Profile#payway_rsa_public_key. Refunds can " \
        "still be recorded manually (Refunds::IssueRefund method: \"manual\") without this."
    end

    # merchant_auth = base64(RSA-public-key-encrypt({mc_id, tran_id,
    # refund_amount}) in <=117-byte chunks, concatenated). RSA can only
    # encrypt a block smaller than the key size in one shot (PKCS#1 v1.5
    # padding leaves 11 bytes of overhead), so a payload longer than that has
    # to be split, encrypted chunk-by-chunk, and the ciphertext chunks
    # concatenated — mirroring ABA's own PHP sample byte-for-byte, since
    # there's no cross-language standard for "how RSA-encrypt a >117-byte
    # JSON blob" beyond matching what the receiving end (ABA) expects to
    # decrypt.
    #
    # PKCS1_PADDING (not OAEP) is passed *explicitly* below rather than left
    # as the implicit default — brakeman (WeakRSAKey) flags PKCS1 as
    # insecure and normally OAEP would be the right fix, but this isn't a
    # local design choice: ABA's own reference implementation
    # (https://developer.payway.com.kh/refund-api-14530821e0, "RSA
    # Encryption (PHP)") calls openssl_public_encrypt() with PHP's default
    # padding, which is PKCS1. ABA's server-side decryption is built against
    # that, so switching to OAEP here wouldn't be "more secure", it would
    # just make every refund fail to decrypt. See config/brakeman.ignore for
    # the corresponding suppression — add it via `bin/brakeman -I`, don't
    # hand-edit the fingerprint.
    def build_merchant_auth(tran_id:, amount:)
      payload = { mc_id: @merchant_id, tran_id: tran_id, refund_amount: amount }.to_json
      rsa = OpenSSL::PKey::RSA.new(@rsa_public_key)

      encrypted = +""
      remaining = payload.dup
      until remaining.empty?
        chunk = remaining.byteslice(0, REFUND_ENCRYPTION_CHUNK_SIZE)
        remaining = remaining.byteslice(REFUND_ENCRYPTION_CHUNK_SIZE..) || ""
        encrypted << rsa.public_encrypt(chunk, OpenSSL::PKey::RSA::PKCS1_PADDING)
      end

      Base64.strict_encode64(encrypted)
    rescue OpenSSL::PKey::RSAError => e
      raise ConfigurationError, "ABA PayWay rsa_public_key is invalid or malformed: #{e.message}"
    end

    def format_time(time)
      time.strftime("%Y%m%d%H%M%S")
    end

    # ABA requires whole numbers for KHR and 2-decimal strings for everything else.
    def format_amount(amount_cents, currency)
      if currency.to_s.casecmp("khr").zero?
        (amount_cents / 100.0).round.to_s
      else
        format("%.2f", amount_cents / 100.0)
      end
    end

    # Base64(HMAC-SHA512(concatenated params, api_key))
    def sign(*parts)
      data = parts.map(&:to_s).join
      digest = OpenSSL::HMAC.digest("sha512", @api_key, data)
      Base64.strict_encode64(digest)
    end

    def post_json(path, body)
      uri = URI.join(@base_url, path)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 15

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = http.request(request)
      parsed = JSON.parse(response.body, symbolize_names: true)

      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError, "ABA PayWay HTTP #{response.code}: #{parsed.dig(:status, :message) || response.body}"
      end

      parsed
    rescue JSON::ParserError => e
      raise RequestError, "ABA PayWay returned invalid JSON: #{e.message}"
    rescue Timeout::Error, Errno::ECONNREFUSED, SocketError => e
      raise RequestError, "ABA PayWay request failed: #{e.message}"
    end
  end
end
