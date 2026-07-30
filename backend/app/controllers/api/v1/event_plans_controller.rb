module Api
  module V1
    # Public, read-only listing of the pricing tiers organizers can publish
    # under. No auth required — used on the marketing pricing page as well
    # as the authenticated publish flow.
    class EventPlansController < BaseController
      # GET /api/v1/event_plans
      def index
        plans = Event::PLANS.map do |id, details|
          {
            id: id,
            label: details[:label],
            capacity: details[:capacity],
            price_cents: details[:price_cents]
          }
        end
        render json: { plans: plans }
      end
    end
  end
end
