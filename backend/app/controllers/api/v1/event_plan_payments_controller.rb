module Api
  module V1
    class EventPlanPaymentsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/events/:event_id/plan_payments
      # Starts (or completes, for the free tier / a $0 delta) the "pay for a
      # plan" flow for one of the current user's events — both the initial
      # publish, and (see #published_plan_change_guard! and
      # #amount_already_paid_cents below) changing plan on an already-
      # published event.
      def create
        event = find_authorized_event!(params[:event_id], :manage_plan, scope: Event.includes(:event_types))

        plan = params[:plan].to_s
        details = Event::PLANS[plan]
        unless details
          render json: { error: "Unknown plan." }, status: :unprocessable_entity
          return
        end

        # Reject upfront, before charging anything (or applying the plan),
        # if the event doesn't actually fit under it — either its own types'
        # combined limit, or (only relevant once people can already be
        # registered, i.e. a change on a published event) how many are
        # actually registered right now. Checked here rather than relying
        # solely on Event's own capacity validation because that only runs
        # once we try to persist the update — we never want to take an
        # organizer's payment and then fail to actually apply the plan.
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

        registered_count = event.registrations.active.count
        if registered_count > details[:capacity]
          render json: {
            error: "The #{details[:label]} plan allows up to #{details[:capacity]} people, but " \
                   "#{registered_count} are already registered. Pick a plan with room for everyone " \
                   "already signed up.",
            code: "plan_capacity_too_low"
          }, status: :unprocessable_entity
          return
        end

        if event.is_published?
          return unless published_plan_change_guard!(event, plan)
          charge_amount = [ details[:price_cents] - amount_already_paid_cents(event), 0 ].max
        else
          # Re-publishing under the same plan the organizer already paid for
          # (e.g. after unpublishing) doesn't require a new charge.
          if event.plan == plan
            event.update!(is_published: true)
            render json: { event: event_json(event) }, status: :created
            return
          end
          charge_amount = details[:price_cents]
        end

        tran_id = "pln#{SecureRandom.alphanumeric(14)}"

        plan_payment = event.event_plan_payments.create!(
          user: current_user,
          plan: plan,
          tran_id: tran_id,
          amount_cents: charge_amount,
          currency: "usd",
          status: "pending",
          expires_at: 15.minutes.from_now
        )

        # Nothing to charge — either the free tier (initial publish), a
        # downgrade (never charged, never refunded), or an upgrade back to a
        # plan whose price is already covered by what's been paid for this
        # event before (the high-water-mark rule in
        # #amount_already_paid_cents). Apply immediately, no gateway involved.
        if charge_amount.zero?
          plan_payment.mark_paid!
          render json: { event: event_json(event.reload), plan_payment: plan_payment_json(plan_payment) }, status: :created
          return
        end

        begin
          profile = current_user.profile
          response = AbaPayway::Client.new.generate_qr(
            tran_id: tran_id,
            amount_cents: charge_amount,
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
        plan_payment = EventPlanPayment.includes(:event).find(params[:id])
        # Raising rather than rendering keeps the existing "Payment not
        # found" 404 below — this used to be expressed as a creator_id scope
        # on the query itself, which conflated "doesn't exist" with "not
        # yours" in exactly the same way.
        raise ActiveRecord::RecordNotFound unless event_permits?(plan_payment.event, :manage_plan)

        refresh_if_stale!(plan_payment)

        render json: { plan_payment: plan_payment_json(plan_payment), event: event_json(plan_payment.event) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Payment not found" }, status: :not_found
      end

      private

      # Guards specific to changing plan on an event that's already
      # published (as opposed to the initial publish flow above). Renders
      # its own error response and returns false when blocked; the caller
      # (#create) bails out in that case.
      def published_plan_change_guard!(event, plan)
        if event.plan == plan
          render json: { error: "This event is already on this plan." }, status: :unprocessable_entity
          return false
        end

        # Block starting a second plan change while an earlier one hasn't
        # resolved yet — same reasoning as not letting a guest submit two
        # concurrent registrations. An expired attempt doesn't count; the
        # organizer should be able to just try again.
        if event.event_plan_payments.pending.where("expires_at > ?", Time.current).exists?
          render json: {
            error: "A plan change is already in progress for this event. Wait for it to complete or expire, then try again.",
            code: "plan_change_pending"
          }, status: :unprocessable_entity
          return false
        end

        true
      end

      # High-water-mark rule: an organizer never pays twice for capacity
      # they've already bought for this event, even after downgrading (which
      # is never refunded — see EventPlanPayment#mark_paid!) and later
      # upgrading back. Every *paid* EventPlanPayment row represents an
      # actual charge already made (the full tier price on first publish,
      # the delta on every change since — see #create above; downgrades
      # always charge 0), so their sum is exactly the highest plan price
      # ever reached for this event, without needing a separate running-total
      # column to keep in sync.
      def amount_already_paid_cents(event)
        event.event_plan_payments.where(status: "paid").sum(:amount_cents)
      end

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
