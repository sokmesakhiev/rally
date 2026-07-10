module Api
  module V1
    module Webhooks
      # Receives payment notifications from ABA PayWay once a KHQR code has
      # been paid. The webhook payload itself is NOT cryptographically signed
      # (ABA's KHQR webhook doesn't include a hash), so we treat it only as a
      # trigger — the actual status change always comes from an authenticated
      # server-to-server Check Transaction call, never from the payload alone.
      class AbaPaywayController < ApplicationController
        # POST /api/v1/webhooks/aba_payway
        def create
          tran_id = params[:merchant_ref].presence || params[:tran_id].presence

          payment = tran_id.present? ? Payment.find_by(tran_id: tran_id) : nil

          if payment.nil?
            Rails.logger.warn("[aba_payway webhook] unknown tran_id=#{tran_id.inspect}")
            head :ok and return
          end

          verify_and_apply!(payment)

          head :ok
        rescue => e
          # Always ack with 200 so ABA doesn't endlessly retry a broken payload;
          # log server-side so we can investigate.
          Rails.logger.error("[aba_payway webhook] error: #{e.class} #{e.message}")
          head :ok
        end

        private

        def verify_and_apply!(payment)
          return unless payment.pending?

          response = AbaPayway::Client.new.check_transaction(tran_id: payment.tran_id)
          return unless response.dig(:status, :code).to_s == "00"

          data = response[:data] || {}
          return unless data[:payment_status] == "APPROVED"

          payment.update!(status: "approved", paid_at: Time.current, raw_response: response)
          payment.registration.mark_paid_from_payment!(payment)
          RegistrationMailer.payment_received(payment.registration).deliver_later
        rescue AbaPayway::Error => e
          Rails.logger.error("[aba_payway webhook] check_transaction failed: #{e.message}")
        end
      end
    end
  end
end
