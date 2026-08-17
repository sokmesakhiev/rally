# frozen_string_literal: true

# Validates POST /api/v1/payments/:payment_id/refunds. amount_cents is
# optional — Api::V1::RefundsController defaults it to the payment's full
# remaining refundable balance when omitted, so "refund everything left"
# doesn't require the caller to look up and echo back an exact number.
# method defaults to "gateway" (see Refund::METHODS) the same way.
class RefundCreateRequestSchema < ApplicationRequestSchema
  params do
    required(:refund).hash do
      optional(:amount_cents).maybe(:integer)
      optional(:refund_method).filled(:string, included_in?: Refund::METHODS)
      optional(:reason).maybe(:string)
    end
  end

  rule(refund: :amount_cents) do
    amount = values[:refund][:amount_cents]
    if amount && amount <= 0
      key([ :refund, :amount_cents ]).failure("must be greater than 0")
    end
  end

  # Mirrors Refund#reason's own presence-if-manual validation (see
  # app/models/refund.rb) — checked here too for an early, specific error;
  # the model validation remains the real backstop for anything that reaches
  # Refund.create! without going through this schema.
  rule(refund: %i[ refund_method reason]) do
    method = values[:refund][:refund_method] || "gateway"
    reason = values[:refund][:reason]
    if method == "manual" && reason.blank?
      key([ :refund, :reason ]).failure("is required for a manual refund")
    end
  end
end
