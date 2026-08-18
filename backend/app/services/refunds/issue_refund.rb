# frozen_string_literal: true

module Refunds
  # Issues a refund against a Payment — either through ABA PayWay's Refund
  # API (method: "gateway", the default) or as a manual/logged entry
  # (method: "manual", for money that already moved outside Rally — bank
  # transfer, cash, a refund an organizer issued directly in ABA's own
  # merchant portal). Both paths update the same state afterwards: Payment's
  # running refunded_amount_cents/status, the Registration's payment_status
  # (and, for a full refund, status: "cancelled" — freeing the capacity slot
  # via Registration::active, see that model), and offer the freed spot to
  # the waitlist.
  #
  # Mirrors Payments::CreatePayment's shape: framework-agnostic (plain values
  # in, a Result out), only PayWay's own error modes are captured here —
  # actual bugs (bad payment state passed in, AR validation failures) still
  # raise. The caller (Api::V1::RefundsController) maps Result#status to the
  # right HTTP status.
  class IssueRefund
    Result = Struct.new(:status, :refund, :error, keyword_init: true) do
      def success?
        status == :succeeded
      end
    end

    def initialize(payment:, amount_cents:, initiated_by:, refund_method: "gateway", reason: nil)
      @payment = payment
      @amount_cents = amount_cents
      @initiated_by = initiated_by
      @refund_method = refund_method
      @reason = reason
    end

    def call
      return not_refundable_result unless @payment.refundable?
      return invalid_amount_result unless valid_amount?

      @refund_method == "manual" ? issue_manual_refund : issue_gateway_refund
    end

    private

    def valid_amount?
      @amount_cents.present? && @amount_cents.positive? && @amount_cents <= @payment.remaining_refundable_cents
    end

    def issue_manual_refund
      refund = nil

      ActiveRecord::Base.transaction do
        refund = create_refund_record(status: "succeeded", refunded_at: Time.current)
        apply_refund!(refund)
      end

      RegistrationMailer.refund_issued(@payment.registration, refund).deliver_later
      Result.new(status: :succeeded, refund: refund)
    end

    def issue_gateway_refund
      response = request_refund

      if response.nil?
        failed = create_refund_record(status: "failed", raw_response: { error: @gateway_error_message })
        return gateway_error_result(failed)
      end

      unless success_response?(response)
        failed = create_refund_record(status: "failed", raw_response: response)
        return declined_result(failed, response)
      end

      refund = nil
      ActiveRecord::Base.transaction do
        refund = create_refund_record(status: "succeeded", raw_response: response, refunded_at: Time.current)
        apply_refund!(refund)
      end

      RegistrationMailer.refund_issued(@payment.registration, refund).deliver_later
      Result.new(status: :succeeded, refund: refund)
    end

    # Returns the parsed PayWay response, or nil if the gateway itself raised
    # (network error, missing rsa_public_key, bad credentials, etc.) —
    # distinct from PayWay responding normally with a decline (e.g. PTL37,
    # PTL57), which is a non-nil response with a non-"00" status code
    # (handled by the caller via success_response?).
    def request_refund
      AbaPayway::Client.for_event(@payment.registration.event).refund(
        tran_id: @payment.tran_id,
        amount_cents: @amount_cents,
        currency: @payment.currency
      )
    rescue AbaPayway::Error => e
      @gateway_error_message = e.message
      nil
    end

    def success_response?(response)
      response.dig(:status, :code).to_s == "00"
    end

    def create_refund_record(status:, raw_response: {}, refunded_at: nil)
      @payment.refunds.create!(
        initiated_by: @initiated_by,
        amount_cents: @amount_cents,
        refund_method: @refund_method,
        status: status,
        reason: @reason,
        raw_response: raw_response,
        refunded_at: refunded_at
      )
    end

    # Whether this refund exhausts what's left to refund must be computed
    # against the payment's state *before* this refund is applied — checked
    # here, not re-derived after @payment.update!, since remaining_refundable_cents
    # would otherwise already reflect this refund and always read 0.
    def apply_refund!(refund)
      full = @amount_cents >= @payment.remaining_refundable_cents

      @payment.update!(
        refunded_amount_cents: @payment.refunded_amount_cents + @amount_cents,
        status: full ? "refunded" : "partially_refunded"
      )
      @payment.registration.apply_refund!(@amount_cents, full: full)

      # A full refund frees the capacity slot (Registration::active excludes
      # "cancelled") — offer it to whoever's been waiting longest, same as
      # RegistrationsController#destroy does for an organizer-removed
      # participant. A partial refund leaves the registration confirmed, so
      # nothing opened up.
      Waitlists::PromoteNext.call(@payment.registration.event) if full
    end

    def not_refundable_result
      Result.new(status: :not_refundable,
        error: "This payment can't be refunded (not approved, or already fully refunded).")
    end

    def invalid_amount_result
      Result.new(status: :invalid_amount,
        error: "Refund amount must be greater than 0 and at most " \
               "#{@payment.remaining_refundable_cents} cents (the amount still refundable).")
    end

    def gateway_error_result(refund)
      Result.new(status: :gateway_error, refund: refund, error: "Could not process refund: #{@gateway_error_message}")
    end

    def declined_result(refund, response)
      Result.new(status: :declined, refund: refund,
        error: response.dig(:status, :message) || "Refund was declined.")
    end
  end
end
