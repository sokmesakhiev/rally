# frozen_string_literal: true

module Registrations
  # A participant cancelling their own registration, with the refund decided
  # by the policy they agreed to at checkout rather than by a human.
  #
  # platform-payments-tickets.md Ticket E. Deliberately built on top of
  # Refunds::IssueRefund rather than beside it: that service already handles
  # the gateway/manual split, the running refunded_amount_cents, the
  # registration's payment_status, and offering the freed spot to the
  # waitlist. All of that still applies — the only new thing here is *who
  # decides the amount*, and that it's nobody.
  #
  # Three outcomes worth distinguishing, because they come from the three
  # states a refund policy can be in (see RefundPolicy):
  #
  #   no policy + money paid  → :requires_organizer. Refused, deliberately.
  #                             The host never set terms, so the refund is a
  #                             conversation; silently cancelling would cost
  #                             the participant money they might have got back.
  #   policy says 0%          → :cancelled. The spot is freed and nothing is
  #                             refunded, which the caller must say plainly.
  #   policy says something    → :cancelled_with_refund.
  class Cancel
    Result = Struct.new(:status, :registration, :refund_cents, :refunds, :error, keyword_init: true) do
      def success?
        %i[cancelled cancelled_with_refund].include?(status)
      end
    end

    def initialize(registration:, initiated_by:, at: Time.current, reason: nil)
      @registration = registration
      @initiated_by = initiated_by
      @at = at
      @reason = reason
    end

    def call
      return already_cancelled_result if @registration.status == "cancelled"

      # Computed before anything mutates amount_paid_cents — Registration
      # #apply_refund! reduces it as refunds land, so asking afterwards would
      # give a smaller (and wrong) answer.
      entitlement = @registration.refund_entitlement_cents(at: @at)
      return requires_organizer_result if entitlement.nil? && money_at_stake?

      refundable = total_refundable_cents
      # Cap at what the payments can actually still give back. The two can
      # differ when a partial refund already happened, or when the
      # registration was only part-paid.
      amount = [ entitlement.to_i, refundable ].min

      return cancel_without_refund if amount <= 0

      cancel_with_refund(amount)
    end

    private

    def money_at_stake?
      @registration.amount_paid_cents.to_i.positive?
    end

    def refundable_payments
      @refundable_payments ||= @registration.payments.select(&:refundable?)
    end

    def total_refundable_cents
      refundable_payments.sum(&:remaining_refundable_cents)
    end

    def cancel_without_refund
      cancel_registration!
      Result.new(status: :cancelled, registration: @registration.reload, refund_cents: 0, refunds: [])
    end

    def cancel_with_refund(amount)
      refunds = []
      remaining = amount

      # Usually one payment. More than one happens when a registration was
      # paid in instalments or re-attempted, and the entitlement has to be
      # spread across them rather than charged wholly to the first.
      refundable_payments.each do |payment|
        break if remaining <= 0

        slice = [ remaining, payment.remaining_refundable_cents ].min
        result = issue_refund(payment, slice)

        # Stop at the first failure rather than pressing on. A partial
        # success is reported as such — the refunds that did land are real
        # and must not be silently discarded or retried blindly.
        return gateway_failure_result(result, refunds, amount - remaining) unless result.success?

        refunds << result.refund
        remaining -= slice
      end

      # IssueRefund only cancels the registration when a refund exhausts its
      # payment. A participant cancelling with a 50% entitlement still gives
      # up their spot, so cancel here if that didn't already happen — and
      # only then, since promoting from the waitlist twice for one freed spot
      # would over-fill the event.
      cancel_registration! unless @registration.reload.status == "cancelled"

      Result.new(
        status: :cancelled_with_refund,
        registration: @registration.reload,
        refund_cents: amount - remaining,
        refunds: refunds
      )
    end

    def issue_refund(payment, amount_cents)
      Refunds::IssueRefund.new(
        payment: payment,
        amount_cents: amount_cents,
        initiated_by: @initiated_by,
        refund_method: "gateway",
        reason: @reason.presence || "Cancelled by participant under the event's refund policy"
      ).call
    end

    def cancel_registration!
      @registration.update!(status: "cancelled")
      Waitlists::PromoteNext.call(@registration.event)
    end

    def already_cancelled_result
      Result.new(status: :already_cancelled, registration: @registration,
        error: "This registration has already been cancelled.")
    end

    def requires_organizer_result
      Result.new(status: :requires_organizer, registration: @registration,
        error: "This event has no refund policy, so cancelling a paid registration " \
               "has to be arranged with the organizer.")
    end

    def gateway_failure_result(result, refunds, refunded_so_far)
      Result.new(status: :refund_failed, registration: @registration.reload,
        refund_cents: refunded_so_far, refunds: refunds, error: result.error)
    end
  end
end
