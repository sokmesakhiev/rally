module Api
  module V1
    class PaymentsController < BaseController
      # Not authenticate_user! — a payment can be started/polled either by a
      # signed-in owner of the registration, or anonymously by a guest whose
      # email/phone matches the registration's account (see
      # guest_contact_matches? below and Registrations::GuestCheckout, which
      # never issues a session for a guest checkout in the first place).
      # authenticate_user_optional! still enforces the suspended/deleted
      # account checks when a token *is* present — it only skips the "no
      # token at all" error.
      before_action :authenticate_user_optional!

      # POST /api/v1/registrations/:registration_id/payments
      # Creates a new ABA KHQR payment attempt for a registration and returns
      # the QR payload for the frontend to render / poll. Implementation
      # lives in Payments::CreatePayment — this action just finds the
      # registration, authorizes the request, delegates, and maps the result
      # to a response.
      def create
        registration = Registration.includes(:event, :event_types, user: :profile).find(params[:registration_id])
        unless payer_authorized?(registration)
          render json: { error: "Registration not found" }, status: :not_found
          return
        end

        result = Payments::CreatePayment.new(
          registration: registration,
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
        payment = Payment.includes(registration: { user: :profile }).find(params[:id])
        unless payer_authorized?(payment.registration)
          render json: { error: "Payment not found" }, status: :not_found
          return
        end

        refresh_if_stale!(payment)

        render json: { payment: payment_json(payment) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Payment not found" }, status: :not_found
      end

      private

      # True when this request has proven a right to act on `registration`'s
      # payment — either a session belonging to the registrant, or (for the
      # no-login guest checkout path — see GuestCheckout) an `email`/`phone`
      # param matching the registrant's own contact info. Same trust level
      # GuestCheckout itself uses to attach a registration in the first
      # place: knowing the contact info is sufficient, a password isn't
      # required. Returns false (not found, not forbidden — same
      # privacy-through-obscurity as the rest of this app) for anyone else,
      # including a *different* signed-in user.
      def payer_authorized?(registration)
        return true if current_user && registration.user_id == current_user.id
        return false if current_user # signed in as someone else — never fall through to guest matching

        guest_contact_matches?(registration)
      end

      def guest_contact_matches?(registration)
        payer = registration.user
        return false unless payer

        email = params[:email].to_s.downcase.strip.presence
        phone = params[:phone].to_s.strip.presence
        return false if email.blank? && phone.blank?

        (email.present? && !payer.email_auto_generated? && payer.email == email) ||
          (phone.present? && payer.profile&.phone == phone)
      end

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
          if payment.registration.wants_notification?(:payment_received)
            RegistrationMailer.payment_received(payment.registration).deliver_later
            Notifications::RegistrationPush.payment_received(payment.registration)
          end
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
