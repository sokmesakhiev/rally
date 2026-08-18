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

          if current_user.admin? && !organizer?(payment)
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

      # Organizer (the event's creator) or a Rally admin — mirrors
      # RegistrationsController's `event.creator_id == current_user.id`
      # checks, plus an admin override. Renders and returns nil (not a
      # boolean) on failure so callers can `return unless payment`.
      def find_authorized_payment
        payment = Payment.includes(registration: :event).find(params[:payment_id])
        return payment if organizer?(payment) || current_user.admin?

        render json: { error: "Forbidden" }, status: :forbidden
        nil
      end

      def organizer?(payment)
        payment.registration.event.creator_id == current_user.id
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
