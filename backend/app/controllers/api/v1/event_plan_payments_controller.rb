module Api
  module V1
    class EventPlanPaymentsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/events/:event_id/plan_payments
      # Starts (or completes, for the free tier) the "pay to publish" flow
      # for one of the current user's events.
      def create
        event = current_user.events.includes(:event_types).find(params[:event_id])

        if event.is_published?
          render json: { error: "This event is already published." }, status: :unprocessable_entity
          return
        end

        plan = params[:plan].to_s
        details = Event::PLANS[plan]
        unless details
          render json: { error: "Unknown plan." }, status: :unprocessable_entity
          return
        end

        # Reject upfront, before charging anything (or publishing the free
        # tier), if the event's own types already add up to more people than
        # this plan allows. Checked here rather than relying solely on
        # Event's own capacity validation because that only runs once we try
        # to persist the update — we never want to take an organizer's
        # payment and then fail to actually publish the event.
        combined_type_capacity = event.combined_event_type_capacity
        if combined_type_capacity > details[:capacity]
          render json: {
            error: "The #{details[:label]} plan allows up to #{details[:capacity]} people, but " \
                   "your event types add up to #{combined_type_capacity} combined. Pick a larger " \
                   "plan or lower your event types' limits.",
            code: "plan_capacity_too_low"
          }, status: :unprocessable_entity
          return
        end

        # Re-publishing under the same plan the organizer already paid for
        # (e.g. after unpublishing) doesn't require a new charge.
        if event.plan == plan
          event.update!(is_published: true)
          render json: { event: event_json(event) }, status: :created
          return
        end

        tran_id = "pln#{SecureRandom.alphanumeric(14)}"

        plan_payment = event.event_plan_payments.create!(
          user: current_user,
          plan: plan,
          tran_id: tran_id,
          amount_cents: details[:price_cents],
          currency: "usd",
          status: "pending",
          expires_at: 15.minutes.from_now
        )

        # Free tier — nothing to charge, publish immediately.
        if details[:price_cents].zero?
          plan_payment.mark_paid!
          render json: { event: event_json(event.reload), plan_payment: plan_payment_json(plan_payment) }, status: :created
          return
        end

        begin
          profile = current_user.profile
          response = AbaPayway::Client.new.generate_qr(
            tran_id: tran_id,
            amount_cents: details[:price_cents],
            currency: "usd",
            lifetime_minutes: 15,
            first_name: profile&.display_name.presence || "Rally",
            last_name: "Organizer",
            email: current_user.email,
            callback_url: "#{ENV.fetch('BACKEND_URL', request.base_url)}/api/v1/webhooks/aba_payway"
          )
        rescue AbaPayway::Error => e
          plan_payment.update!(status: "declined", raw_response: { error: e.message })
          render json: { error: "Could not start payment: #{e.message}" }, status: :bad_gateway
          return
        end

        status_code = response.dig(:status, :code)
        unless status_code.to_s == "0"
          plan_payment.update!(status: "declined", raw_response: response)
          render json: { error: response.dig(:status, :message) || "Payment could not be started." }, status: :unprocessable_entity
          return
        end

        plan_payment.update!(
          qr_string: response[:qrString],
          abapay_deeplink: response[:abapay_deeplink],
          raw_response: response
        )

        render json: { plan_payment: plan_payment_json(plan_payment) }, status: :created
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # GET /api/v1/plan_payments/:id — poll payment status.
      def show
        plan_payment = EventPlanPayment.joins(:event).where(events: { creator_id: current_user.id }).find(params[:id])

        refresh_if_stale!(plan_payment)

        render json: { plan_payment: plan_payment_json(plan_payment), event: event_json(plan_payment.event) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Payment not found" }, status: :not_found
      end

      private

      def refresh_if_stale!(plan_payment)
        return unless plan_payment.pending?

        if plan_payment.expired?
          plan_payment.update!(status: "expired")
          return
        end

        return if plan_payment.updated_at > 5.seconds.ago

        begin
          response = AbaPayway::Client.new.check_transaction(tran_id: plan_payment.tran_id)
        rescue AbaPayway::Error
          return
        end

        return unless response.dig(:status, :code).to_s == "00"

        data = response[:data] || {}
        case data[:payment_status]
        when "APPROVED"
          plan_payment.mark_paid!(raw_response: response)
        when "DECLINED"
          plan_payment.update!(status: "declined", raw_response: response)
        when "CANCELLED"
          plan_payment.update!(status: "cancelled", raw_response: response)
        else
          plan_payment.update!(raw_response: response)
        end
      end

      def plan_payment_json(plan_payment)
        {
          id: plan_payment.id,
          event_id: plan_payment.event_id,
          plan: plan_payment.plan,
          status: plan_payment.status,
          amount_cents: plan_payment.amount_cents,
          currency: plan_payment.currency,
          qr_string: plan_payment.qr_string,
          abapay_deeplink: plan_payment.abapay_deeplink,
          expires_at: plan_payment.expires_at,
          paid_at: plan_payment.paid_at,
          created_at: plan_payment.created_at
        }
      end

      def event_json(event)
        {
          id: event.id,
          plan: event.plan,
          capacity: event.capacity,
          is_published: event.is_published
        }
      end
    end
  end
end
