module Api
  module V1
    module Admin
      class EventsController < BaseController
        # GET /api/v1/admin/events
        # Unlike the public EventsController#index this is NOT scoped to
        # published/upcoming — moderation needs to see drafts and past events
        # too, since that's where reported content often sits.
        def index
          validate_params_with_schema(AdminEventIndexRequestSchema) do |validated_params|
            page     = validated_params[:page] || 1
            per_page = validated_params[:per_page] || AdminEventIndexRequestSchema::DEFAULT_PER_PAGE

            scope = Event.all
            scope = scope.published                        if validated_params[:status] == "published"
            scope = scope.where(is_published: false)       if validated_params[:status] == "draft"
            scope = scope.search(validated_params[:q])
            scope = scope.in_category(validated_params[:category])

            total = scope.count

            events = scope
              .includes(:registrations, creator: :profile)
              .order(created_at: :desc)
              .offset((page - 1) * per_page)
              .limit(per_page)

            render json: {
              events: events.map { |e| event_json(e) },
              meta: {
                page: page,
                per_page: per_page,
                total_count: total,
                total_pages: total.zero? ? 0 : (total.to_f / per_page).ceil
              }
            }
          end
        end

        # POST /api/v1/admin/events/:id/unpublish
        # The lighter of the two moderation actions: takes an event off the
        # public listing without touching registrations, payments, or the paid
        # plan — so it's reversible by the organizer and safe to use on a
        # report that may turn out to be unfounded.
        def unpublish
          event = Event.find(params[:id])
          event.update!(is_published: false)
          log_admin_action("unpublish_event", event)

          render json: { event: event_json(event.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        # POST /api/v1/admin/events/:id/suspend
        # The stronger moderation lever — see event-freeze-and-terms-tickets.md's
        # Ticket A/B (named/shaped to match User#suspend!, since it's the
        # same admin-only-reversible-lock concept applied to an event
        # instead of an account). Unlike #unpublish, this is NOT reversible
        # by the organizer: EventAuthorization#event_permits? denies every
        # mutating capability (including the owner's own unpublish/update/
        # republish) while suspended_at is set, so only #unsuspend below can
        # undo it. Suspending an already-suspended event is allowed and
        # simply overwrites the reason — an admin refining their note
        # shouldn't have to unsuspend first.
        #
        # Emails the owner once suspended (EventMailer#suspended,
        # unconditional — see its own comment for why this isn't gated
        # behind a notify_* opt-out) so they find out why, not just that
        # their event vanished from public listings.
        def suspend
          event = Event.find(params[:id])

          validate_params_with_schema(AdminSuspendEventRequestSchema) do |validated_params|
            event.suspend!(reason: validated_params[:reason])
            log_admin_action("suspend_event", event)
            EventMailer.suspended(event).deliver_later

            render json: { event: event_json(event.reload) }
          end
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        # POST /api/v1/admin/events/:id/unsuspend
        # Does not re-publish — same reasoning as Event#unsuspend! itself.
        # Harmless no-op on an event that was never suspended, rather than
        # an error, since there's nothing unsafe about calling it twice.
        def unsuspend
          event = Event.find(params[:id])
          event.unsuspend!
          log_admin_action("unsuspend_event", event)

          render json: { event: event_json(event.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        # DELETE /api/v1/admin/events/:id
        # Soft-delete (see Event#discard!) — hides the event, its
        # registrations, and its waitlist entries rather than destroying
        # them. Still requires an explicit confirm flag so it can't be
        # reached by a stray DELETE, and still refuses outright once money
        # has changed hands — a paid event needs a refund decision first,
        # not a silent removal from listings.
        def destroy
          event = Event.find(params[:id])

          unless ActiveModel::Type::Boolean.new.cast(params[:confirm])
            render json: {
              error: "Deleting an event is irreversible. Re-send with confirm=true.",
              code: "confirmation_required"
            }, status: :unprocessable_entity
            return
          end

          paid_registrations = event.registrations.where(payment_status: "paid").count
          if paid_registrations.positive?
            render json: {
              error: "This event has #{paid_registrations} paid registration(s). " \
                     "Unpublish it instead, and resolve refunds before deleting.",
              code: "has_paid_registrations"
            }, status: :unprocessable_entity
            return
          end

          log_admin_action("destroy_event", event)
          event.discard!

          render json: { message: "Event deleted" }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Event not found" }, status: :not_found
        end

        private

        def event_json(event)
          {
            id: event.id,
            title: event.title,
            category: event.category,
            location: event.location,
            start_at: event.start_at,
            is_published: event.is_published,
            suspended: event.suspended?,
            suspension_reason: event.suspension_reason,
            suspended_at: event.suspended_at,
            plan: event.plan,
            capacity: event.capacity,
            price_cents: event.price_cents,
            currency: event.currency,
            registrations_count: event.registrations.size,
            deleted: event.discarded?,
            creator: {
              id: event.creator_id,
              email: event.creator.email,
              display_name: event.creator.profile&.display_name,
              suspended: event.creator.suspended?
            },
            created_at: event.created_at
          }
        end
      end
    end
  end
end
