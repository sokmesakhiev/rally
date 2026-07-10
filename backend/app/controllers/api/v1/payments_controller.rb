module Api
  module V1
    class PaymentsController < ApplicationController
      before_action :authenticate_user!

      # POST /api/v1/registrations/:registration_id/payments
      # Creates a new ABA KHQR payment attempt for the current user's registration
      # and returns the QR payload for the frontend to render / poll.
      def create
        registration = current_user.registrations.includes(:event, :event_types).find(params[:registration_id])

        if registration.payment_status == "paid"
          render json: { error: "This registration is already paid." }, status: :unprocessable_entity
          return
        end

        amount_cents = registration.owed_amount_cents
        if amount_cents <= 0
          render json: { error: "This registration has nothing owed." }, status: :unprocessable_entity
          return
        end

        tran_id = "rly#{SecureRandom.alphanumeric(14)}"
        currency = registration.event.currency.presence || "usd"

        payment = registration.payments.create!(
          tran_id: tran_id,
          amount_cents: amount_cents,
          currency: currency,
          status: "pending",
          expires_at: 15.minutes.from_now
        )

        begin
          profile = current_user.profile
          response = AbaPayway::Client.new.generate_qr(
            tran_id: tran_id,
            amount_cents: amount_cents,
            currency: currency,
            lifetime_minutes: 15,
            first_name: profile&.display_name.presence || "Rally",
            last_name: "Participant",
            email: current_user.email,
            callback_url: "#{ENV.fetch('BACKEND_URL', request.base_url)}/api/v1/webhooks/aba_payway"
          )
        rescue AbaPayway::Error => e
          payment.update!(status: "declined", raw_response: { error: e.message })
          render json: { error: "Could not start payment: #{e.message}" }, status: :bad_gateway
          return
        end

        status_code = response.dig(:status, :code)
        unless status_code.to_s == "0"
          payment.update!(status: "declined", raw_response: response)
          render json: { error: response.dig(:status, :message) || "Payment could not be started." }, status: :unprocessable_entity
          return
        end

        payment.update!(
          qr_string: response[:qrString],
          abapay_deeplink: response[:abapay_deeplink],
          raw_response: response
        )

        render json: { payment: payment_json(payment) }, status: :created
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      # GET /api/v1/payments/:id — poll payment status.
      # Refreshes from ABA if still pending and the last check was a while ago.
      def show
        payment = Payment.joins(:registration).where(registrations: { user_id: current_user.id }).find(params[:id])

        refresh_if_stale!(payment)

        render json: { payment: payment_json(payment) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Payment not found" }, status: :not_found
      end

      private

      # Re-checks with ABA at most once every 5s while a payment is pending
      # and not yet expired, so the frontend can poll our endpoint tightly
      # without hammering PayWay directly.
      def refresh_if_stale!(payment)
        return unless payment.pending?

        if payment.expired?
          payment.update!(status: "expired")
          return
        end

        return if payment.updated_at > 5.seconds.ago

        begin
          response = AbaPayway::Client.new.check_transaction(tran_id: payment.tran_id)
        rescue AbaPayway::Error
          return # transient network/API error — keep current status, try again next poll
        end

        return unless response.dig(:status, :code).to_s == "00"

        data = response[:data] || {}
        case data[:payment_status]
        when "APPROVED"
          payment.update!(status: "approved", paid_at: Time.current, raw_response: response)
          payment.registration.mark_paid_from_payment!(payment)
          RegistrationMailer.payment_received(payment.registration).deliver_later
        when "DECLINED"
          payment.update!(status: "declined", raw_response: response)
        when "CANCELLED"
          payment.update!(status: "cancelled", raw_response: response)
        else
          payment.update!(raw_response: response) # still PENDING — just refresh the timestamp
        end
      end

      def payment_json(payment)
        {
          id: payment.id,
          registration_id: payment.registration_id,
          status: payment.status,
          amount_cents: payment.amount_cents,
          currency: payment.currency,
          qr_string: payment.qr_string,
          abapay_deeplink: payment.abapay_deeplink,
          expires_at: payment.expires_at,
          paid_at: payment.paid_at,
          created_at: payment.created_at
        }
      end
    end
  end
end
