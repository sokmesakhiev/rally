module Api
  module V1
    # The public organizer page — see organization-identity-tickets.md's
    # Ticket F (#335). Backs the frontend's /organizers/:slug route (#337).
    #
    # **Deliberately a separate resource from OrganizationsController**, not
    # another action on it. That controller is the management surface: every
    # action requires a relationship, and its payload carries PayWay status,
    # the owner's id, and publish-readiness. This one is world-readable. Two
    # payloads with opposite audiences sharing a serializer is how a private
    # field eventually leaks into a public response, so they don't share one —
    # and the route names (/organizations vs /organizers) make it obvious in
    # routes.rb which is which.
    #
    # No authenticate_user!: anonymous visitors are the point. Nothing here
    # varies by caller, so there's no identify_current_user! either.
    class OrganizersController < BaseController
      # GET /api/v1/organizers/:slug
      def show
        organization = Organization.kept.find_by!(slug: params[:slug])

        # Suspended organizations are not browsable. #suspended? already
        # derives from the owner (see Organization), so an organizer whose
        # account was suspended disappears from here too, without Ticket J's
        # event-level cascade needing to exist yet.
        raise ActiveRecord::RecordNotFound if organization.suspended?

        render json: { organizer: organizer_json(organization) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Organizer not found" }, status: :not_found
      end

      private

      # How many past events to show. Bounded because this is an unauthenticated
      # endpoint and a long-running organizer could otherwise return hundreds of
      # rows to anyone who asks. The full history isn't the point of the page;
      # evidence of a track record is, and events_run already carries the total.
      PAST_EVENTS_LIMIT = 10

      def organizer_json(organization)
        visible = organization.events.publicly_visible

        {
          slug: organization.slug,
          name: organization.name,
          description: organization.description,
          logo_url: organization.logo_url,
          banner_url: organization.banner_url,
          brand_color: organization.brand_color,
          website: organization.website,
          # The organizer's *published* contact details — deliberately not the
          # email they sign in with, which lives on User and never appears here.
          contact_email: organization.contact_email,
          contact_phone: organization.contact_phone,
          facebook_url: organization.facebook_url,
          instagram_url: organization.instagram_url,
          telegram_url: organization.telegram_url,
          verified: organization.verified?,
          # Trust signals — see Organization#events_run/#participants_hosted.
          member_since: organization.created_at,
          events_run: organization.events_run,
          participants_hosted: organization.participants_hosted,
          upcoming_events: visible.upcoming.order(start_at: :asc).map { |e| event_summary_json(e) },
          past_events: visible.ended.order(start_at: :desc).limit(PAST_EVENTS_LIMIT)
                              .map { |e| event_summary_json(e) }
        }
      end

      # A listing-card shape, not EventsController#event_json. Anything an
      # anonymous visitor shouldn't see (creator_id, plan, suspension state)
      # is absent by construction rather than by remembering to strip it.
      def event_summary_json(event)
        {
          id: event.id,
          title: event.title,
          category: event.category,
          location: event.location,
          start_at: event.start_at,
          end_at: event.end_at,
          price_cents: event.price_cents,
          currency: event.currency,
          banner_url: event.banner_url,
          logo_url: event.logo_url,
          brand_color: event.brand_color
        }
      end
    end
  end
end
