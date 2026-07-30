# frozen_string_literal: true

module Payments
  # Extracted from Api::V1::PaymentsController#create, which was doing all of
  # this inline: validate the registration is actually payable, open a
  # pending Payment record, ask ABA PayWay for a QR code, and reconcile the
  # Payment with whatever PayWay said (success / declined / unreachable).
  #
  # Deliberately framework-agnostic — takes plain values in (`registration`,
  # `current_user`, `callback_url`), not the controller/request itself, so
  # it's usable/testable outside of a request cycle. Returns a Result
  # instead of rendering or raising for expected outcomes (already paid,
  # nothing owed, gateway declined/unreachable); the controller maps
  # `Result#status` to the right HTTP status code. Actual bugs (bad
  # registration state, AR validation failures on Payment itself) still
  # raise normally — only PayWay's own error modes are captured here.
  class CreatePayment
    PAYMENT_LIFETIME_MINUTES = 15

    Result = Struct.new(:status, :payment, :error, keyword_init: true) do
      def success?
        status == :created
      end
    end

    def initialize(registration:, current_user:, callback_url:)
      @registration = registration
      @current_user = current_user
      @callback_url = callback_url
    end

    def call
      return already_paid_result if @registration.payment_status == "paid"

      amount_cents = @registration.owed_amount_cents
      return nothing_owed_result if amount_cents <= 0

      payment = open_payment(amount_cents)
      response = request_qr(payment, amount_cents)
      return gateway_error_result(payment) if response.nil?

      unless success_response?(response)
        payment.update!(status: "declined", raw_response: response)
        return declined_result(payment, response)
      end

      payment.update!(
        qr_string: response[:qrString],
        abapay_deeplink: response[:abapay_deeplink],
        raw_response: response
      )

      Result.new(status: :created, payment: payment)
    end

    private

    def open_payment(amount_cents)
      @registration.payments.create!(
        tran_id: "rly#{SecureRandom.alphanumeric(14)}",
        amount_cents: amount_cents,
        currency: currency,
        status: "pending",
        expires_at: PAYMENT_LIFETIME_MINUTES.minutes.from_now
      )
    end

    def currency
      @registration.event.currency.presence || "usd"
    end

    # Returns the parsed PayWay response, or nil if the gateway itself
    # raised (network error, bad credentials, etc.) — distinct from PayWay
    # responding normally with a decline, which is a non-nil response with
    # a non-zero status code (handled by the caller via success_response?).
    def request_qr(payment, amount_cents)
      profile = @current_user.profile
      AbaPayway::Client.for_event(@registration.event).generate_qr(
        tran_id: payment.tran_id,
        amount_cents: amount_cents,
        currency: currency,
        lifetime_minutes: PAYMENT_LIFETIME_MINUTES,
        first_name: profile&.display_name.presence || "Rally",
        last_name: "Participant",
        email: @current_user.email,
        callback_url: @callback_url
      )
    rescue AbaPayway::Error => e
      payment.update!(status: "declined", raw_response: { error: e.message })
      @gateway_error_message = e.message
      nil
    end

    def success_response?(response)
      response.dig(:status, :code).to_s == "0"
    end

    def already_paid_result
      Result.new(status: :already_paid, error: "This registration is already paid.")
    end

    def nothing_owed_result
      Result.new(status: :nothing_owed, error: "This registration has nothing owed.")
    end

    def gateway_error_result(payment)
      Result.new(status: :gateway_error, payment: payment, error: "Could not start payment: #{@gateway_error_message}")
    end

    def declined_result(payment, response)
      Result.new(
        status: :declined,
        payment: payment,
        error: response.dig(:status, :message) || "Payment could not be started."
      )
    end
  end
end
