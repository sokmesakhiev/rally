module Api
  module V1
    module Webhooks
      # Receives payment notifications from ABA PayWay once a KHQR code has
      # been paid. The webhook payload itself is NOT cryptographically signed
      # (ABA's KHQR webhook doesn't include a hash), so we treat it only as a
      # trigger — the actual status change always comes from an authenticated
      # server-to-server Check Transaction call, never from the payload alone.
      class AbaPaywayController < BaseController
        # POST /api/v1/webhooks/aba_payway
        # Handles both kinds of ABA payment in this app: participant
        # registration payments (Payment, tran_id prefix "rly") and
        # organizer publish-plan payments (EventPlanPayment, prefix "pln").
        def create
          tran_id = params[:merchant_ref].presence || params[:tran_id].presence
          payable = tran_id.present? ? (Payment.find_by(tran_id: tran_id) || EventPlanPayment.find_by(tran_id: tran_id)) : nil

          if payable.nil?
            Rails.logger.warn("[aba_payway webhook] unknown tran_id=#{tran_id.inspect}")
            head :ok and return
          end

          verify_and_apply!(payable)

          head :ok
        rescue => e
          # Always ack with 200 so ABA doesn't endlessly retry a broken payload;
          # log server-side so we can investigate.
          Rails.logger.error("[aba_payway webhook] error: #{e.class} #{e.message}")
          head :ok
        end

        private

        def verify_and_apply!(payable)
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
            RegistrationMailer.payment_received(payable.registration).deliver_later
          when EventPlanPayment
            payable.mark_paid!(raw_response: response)
          end
        rescue AbaPayway::Error => e
          Rails.logger.error("[aba_payway webhook] check_transaction failed: #{e.message}")
        end
      end
    end
  end
end
