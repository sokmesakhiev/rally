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
        #
        # Only does a DB lookup here and acks immediately — the actual ABA
        # Check Transaction call (an outbound network request) happens in
        # ProcessAbaPaywayWebhookJob, off the request/response cycle, so a
        # slow or unreachable ABA doesn't turn into a slow/failed webhook ack.
        def create
          tran_id = params[:merchant_ref].presence || params[:tran_id].presence
          payable = tran_id.present? ? (Payment.find_by(tran_id: tran_id) || EventPlanPayment.find_by(tran_id: tran_id)) : nil

          if payable.nil?
            Rails.logger.warn("[aba_payway webhook] unknown tran_id=#{tran_id.inspect}")
          else
            ProcessAbaPaywayWebhookJob.perform_later(payable)
          end

          head :ok
        rescue => e
          # Always ack with 200 so ABA doesn't endlessly retry a broken payload;
          # log server-side so we can investigate.
          Rails.logger.error("[aba_payway webhook] error: #{e.class} #{e.message}")
          head :ok
        end
      end
    end
  end
end
