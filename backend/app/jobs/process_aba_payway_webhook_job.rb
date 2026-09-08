# frozen_string_literal: true

# Extracted from Api::V1::Webhooks::AbaPaywayController#create, which used to
# do this inline before acking the webhook. ABA's KHQR webhook payload isn't
# cryptographically signed, so it's only ever a trigger — the real status
# change always comes from this job's own authenticated Check Transaction
# call, never from the webhook payload alone (see the controller's class
# comment). Moving that outbound call here means the controller can ack
# ABA's webhook immediately after a cheap DB lookup instead of making ABA's
# delivery wait on our own call back out to ABA — most webhook senders treat
# a slow ack as a failure and retry, which was the actual risk with the old
# inline version.
#
# Idempotent: re-running against an already-approved/declined/cancelled
# payable is a no-op (`return unless payable.pending?`), so duplicate
# webhook deliveries or a retried job are both safe.
class ProcessAbaPaywayWebhookJob < ApplicationJob
  queue_as :default

  def perform(payable)
    return unless payable.pending?

    # Payment (attendee → organizer) may have been created under the
    # organizer's own PayWay credentials; EventPlanPayment (organizer →
    # Rally) always uses Rally's platform credentials.
    client = payable.is_a?(Payment) ? AbaPayway::Client.for_event(payable.registration.event) : AbaPayway::Client.new
    response = client.check_transaction(tran_id: payable.tran_id)
    return unless response.dig(:status, :code).to_s == "00"

    data = response[:data] || {}
    return unless data[:payment_status] == "APPROVED"

    case payable
    when Payment
      payable.update!(status: "approved", paid_at: Time.current, raw_response: response)
      payable.registration.mark_paid_from_payment!(payable)
      if payable.registration.wants_notification?(:payment_received)
        RegistrationMailer.payment_received(payable.registration).deliver_later
        Notifications::RegistrationPush.payment_received(payable.registration)
      end
    when EventPlanPayment
      payable.mark_paid!(raw_response: response)
    end
  rescue AbaPayway::Error => e
    Rails.logger.error("[aba_payway webhook job] check_transaction failed: #{e.message}")
  end
end
