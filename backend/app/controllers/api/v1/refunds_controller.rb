module Api
  module V1
    class RefundsController < BaseController
      before_action :authenticate_user!

      # GET /api/v1/payments/:payment_id/refunds — refund history for a payment.
      def index
        payment = find_authorized_payment
        return unless payment

        render json: { refunds: payment.refunds.order(created_at: :desc).map { |r| refund_json(r) } }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Payment not found" }, status: :not_found
      end

      # POST /api/v1/payments/:payment_id/refunds
      # Issues a full or partial refund — see Refunds::IssueRefund for what
      # actually happens (ABA PayWay API call or a manual/logged entry,
      # Payment/Registration state updates, freeing the capacity slot and
      # offering it to the waitlist on a full refund).
      def create
        payment = find_authorized_payment
        return unless payment

        validate_params_with_schema(RefundCreateRequestSchema) do |validated_params|
          refund_params = validated_params[:refund]
          amount_cents = refund_params[:amount_cents] || payment.remaining_refundable_cents

          result = Refunds::IssueRefund.new(
            payment: payment,
            amount_cents: amount_cents,
            initiated_by: current_user,
            refund_method: refund_params[:refund_method] || "gateway",
            reason: refund_params[:reason]
          ).call

          if current_user.admin? && !event_staff?(payment)
            AdminAction.log!(admin: current_user, action: "issue_refund", target: payment)
          end

          case result.status
          when :succeeded
            render json: { refund: refund_json(result.refund), payment: payment_summary_json(payment.reload) },
              status: :created
          when :gateway_error
            render json: { error: result.error }, status: :bad_gateway
          else # :not_refundable, :invalid_amount, :declined
            render json: { error: result.error, refund: result.refund && refund_json(result.refund) }.compact,
              status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Payment not found" }, status: :not_found
      end

      private

      # Whoever may refund this payment: someone with :issue_refund on the
      # payment's event (see EventAuthorization::CAPABILITIES), or a Rally
      # admin. The admin arm is deliberately outside the capability system —
      # it's platform moderation, not a role on this particular event.
      #
      # Renders and returns nil (not a boolean) on failure so callers can
      # `return unless payment`.
      def find_authorized_payment
        payment = Payment.includes(registration: :event).find(params[:payment_id])
        return payment if event_staff?(payment) || current_user.admin?

        render json: { error: "Forbidden" }, status: :forbidden
        nil
      end

      # True when the caller may refund this payment by virtue of their
      # standing on the event itself, as opposed to platform admin rights.
      # #create uses the distinction to decide whether the refund is a
      # moderation action worth writing to AdminAction — an admin refunding
      # an event they run themselves isn't moderating anything.
      def event_staff?(payment)
        event_permits?(payment.registration.event, :issue_refund)
      end

      def refund_json(refund)
        {
          id: refund.id,
          payment_id: refund.payment_id,
          amount_cents: refund.amount_cents,
          refund_method: refund.refund_method,
          status: refund.status,
          reason: refund.reason,
          refunded_at: refund.refunded_at,
          created_at: refund.created_at
        }
      end

      def payment_summary_json(payment)
        {
          id: payment.id,
          status: payment.status,
          amount_cents: payment.amount_cents,
          refunded_amount_cents: payment.refunded_amount_cents,
          remaining_refundable_cents: payment.remaining_refundable_cents
        }
      end
    end
  end
end
