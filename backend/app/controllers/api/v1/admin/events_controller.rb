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

        # DELETE /api/v1/admin/events/:id
        # Destructive and irreversible: cascades to registrations, payments,
        # and survey answers (see the dependent: :destroy chain on Event).
        # Requires an explicit confirm flag so it can't be reached by a stray
        # DELETE, and refuses outright once money has changed hands — a paid
        # event needs a refund decision first, not a silent data deletion.
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
          event.destroy!

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
            plan: event.plan,
            capacity: event.capacity,
            price_cents: event.price_cents,
            currency: event.currency,
            registrations_count: event.registrations.size,
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
