module Api
  module V1
    class PaymentsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/registrations/:registration_id/payments
      # Creates a new ABA KHQR payment attempt for the current user's registration
      # and returns the QR payload for the frontend to render / poll.
      # Implementation lives in Payments::CreatePayment — this action just
      # finds the registration, delegates, and maps the result to a response.
      def create
        registration = current_user.registrations.includes(:event, :event_types).find(params[:registration_id])

        result = Payments::CreatePayment.new(
          registration: registration,
          current_user: current_user,
          callback_url: "#{ENV.fetch('BACKEND_URL', request.base_url)}/api/v1/webhooks/aba_payway"
        ).call

        case result.status
        when :created
          render json: { payment: payment_json(result.payment) }, status: :created
        when :gateway_error
          render json: { error: result.error }, status: :bad_gateway
        else # :already_paid, :nothing_owed, :declined
          render json: { error: result.error }, status: :unprocessable_entity
        end
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
          response = AbaPayway::Client.for_event(payment.registration.event).check_transaction(tran_id: payment.tran_id)
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
