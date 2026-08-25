module Api
  module V1
    class EventsController < BaseController
      before_action :authenticate_user!, only: [ :create, :update, :destroy, :my_events, :unpublish, :activity ]
      before_action :set_event, only: [ :show, :update, :destroy, :unpublish ]
      before_action :authorize_creator!, only: [ :update, :destroy, :unpublish ]

      # GET /api/v1/events — public, published, upcoming
      #
      # Supports ?q= (free-text over title/description/location), ?category=,
      # and ?page=/?per_page= pagination. All optional: a bare request returns
      # the first page with default page size, so older clients keep working.
      #
      # Eager-loads event_types' registration_event_types (plus each one's
      # registration, so EventType#full?/#spots_remaining can check
      # registration.status without an extra query — see those methods) so
      # EventType#spots_remaining (called per type in event_type_json below)
      # reads the preloaded array via #size instead of issuing a fresh COUNT
      # query per event type — this is the highest-traffic endpoint in the
      # app, so that was a real N+1 (1 query for events + 1 per event type).
      def index
        validate_params_with_schema(EventIndexRequestSchema) do |validated_params|
          page     = validated_params[:page] || 1
          per_page = validated_params[:per_page] || EventIndexRequestSchema::DEFAULT_PER_PAGE

          scope = Event.published.upcoming.kept
            .search(validated_params[:q])
            .in_category(validated_params[:category])

          # Count before paginating, and off the eager-loaded relation — a
          # COUNT with includes() would build a needless join.
          total = scope.count

          events = scope
            .includes(event_types: { registration_event_types: :registration })
            .order(start_at: :asc)
            .offset((page - 1) * per_page)
            .limit(per_page)

          render json: {
            events: events.map { |e| event_json(e, include_types: true) },
            meta: {
              page: page,
              per_page: per_page,
              total_count: total,
              total_pages: total.zero? ? 0 : (total.to_f / per_page).ceil
            }
          }
        end
      end

      # GET /api/v1/events/my — current user's created events
      def my_events
        events = current_user.events.kept.includes(:registrations, event_types: { registration_event_types: :registration }).order(start_at: :asc)
        render json: {
          events: events.map { |e|
            # Ruby-side filter, not e.registrations.active.size — .active is a
            # `where`, which would force a fresh query per event instead of
            # using the already-preloaded array above.
            active_count = e.registrations.count { |r| r.status != "cancelled" }
            event_json(e, include_types: true).merge(registrations_count: active_count)
          }
        }
      end

      # GET /api/v1/events/:id
      def show
        @event = Event.includes(:registrations, survey: :survey_questions,
                                 event_types: { registration_event_types: :registration })
          .find(params[:id])
        render json: { event: event_json(@event, include_count: true, include_survey: true, include_types: true) }
      end

      # POST /api/v1/events
      def create
        validate_params_with_schema(EventRequestSchema) do |validated_params|
          event = current_user.events.create!(validated_params[:event])

          render json: { event: event_json(event, include_types: true) }, status: :created
        end
      rescue ActiveRecord::RecordInvalid => e
        # EventRequestSchema deliberately only mirrors *some* of Event's
        # validations (see its class comment) — things like title length,
        # category inclusion, or end_after_start still only exist on the
        # model, so create! can still legitimately raise here.
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/events/:id
      def update
        validate_params_with_schema(EventUpdateRequestSchema) do |validated_params|
          if @event.update(validated_params[:event])
            log_event_details_changes
            render json: { event: event_json(@event, include_types: true) }
          else
            render json: { error: @event.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      end

      # DELETE /api/v1/events/:id — soft-delete (see Event#discard!); the
      # event, its registrations, and its waitlist entries are hidden, not
      # destroyed.
      def destroy
        @event.discard!
        render json: { message: "Event deleted" }
      end

      # GET /api/v1/events/:id/activity — organizer-only history of
      # participant removals and price/date changes on this event. See
      # EventActivity's class comment for why this is separate from the
      # admin-only AdminAction log.
      def activity
        event = current_user.events.kept.find(params[:id])
        activities = event.event_activities.recent.includes(:actor)

        render json: { activities: activities.map { |a| event_activity_json(a) } }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # POST /api/v1/events/:id/unpublish
      # Takes an event down without affecting its paid plan — republishing
      # under the same plan later is free (see EventPlanPaymentsController).
      def unpublish
        @event.update!(is_published: false)
        render json: { event: event_json(@event, include_types: true) }
      end

      private

      # Only these two are logged today — see EventActivity::ACTIONS'
      # comment for why this stays narrow rather than tracking every field.
      TRACKED_DETAIL_CHANGES = %w[price_cents start_at end_at].freeze

      # Uses saved_changes (populated by AR right after a successful
      # #update), not a diff against the request params — so this only
      # fires when a tracked value actually changed, not just whenever the
      # field happened to be present in the request body with its existing
      # value.
      def log_event_details_changes
        changed = @event.saved_changes.slice(*TRACKED_DETAIL_CHANGES)
        return if changed.empty?

        EventActivity.log!(
          event: @event,
          actor: current_user,
          action: "update_event_details",
          metadata: changed.transform_values { |(from, to)| { "from" => from, "to" => to } }
        )
      end

      def event_activity_json(activity)
        {
          id: activity.id,
          action: activity.action,
          actor_name: activity.actor.profile&.display_name.presence || activity.actor.email,
          metadata: activity.metadata,
          created_at: activity.created_at
        }
      end

      def set_event
        @event = Event.kept.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      def authorize_creator!
        unless @event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
        end
      end

      def event_json(event, include_count: false, include_survey: false, include_types: false)
        json = {
          id: event.id,
          creator_id: event.creator_id,
          survey_id: event.survey_id,
          title: event.title,
          description: event.description,
          category: event.category,
          location: event.location,
          # decimal columns serialize as strings by default (BigDecimal#as_json)
          # — cast to Float so the frontend gets real JSON numbers.
          latitude: event.latitude&.to_f,
          longitude: event.longitude&.to_f,
          route_map_url: event.route_map_url,
          start_at: event.start_at,
          end_at: event.end_at,
          capacity: event.capacity,
          plan: event.plan,
          price_cents: event.price_cents,
          currency: event.currency,
          is_published: event.is_published,
          brand_color: event.brand_color,
          banner_url: event.banner_url,
          logo_url: event.logo_url,
          certificate_template_url: event.certificate_template_url,
          created_at: event.created_at,
          updated_at: event.updated_at
        }
        # Ruby-side filter, not event.registrations.active.size — .active is a
        # `where`, which would force a fresh query instead of using the
        # already-preloaded array (#show, the only caller with include_count:
        # true, eager-loads :registrations).
        json[:registrations_count] = event.registrations.count { |r| r.status != "cancelled" } if include_count
        if include_survey && event.survey
          json[:survey] = {
            id:        event.survey.id,
            title:     event.survey.title,
            questions: event.survey.survey_questions.map do |q|
              {
                id:            q.id,
                question_text: q.question_text,
                question_type: q.question_type,
                options:       q.options,
                position:      q.position,
                required:      q.required
              }
            end
          }
        end
        if include_types
          json[:event_types] = event.event_types.map { |t| event_type_json(t) }
        end
        json
      end

      def event_type_json(type)
        {
          id:          type.id,
          event_id:    type.event_id,
          name:        type.name,
          description: type.description,
          capacity:    type.capacity,
          price_cents: type.price_cents,
          position:    type.position,
          spots_remaining: type.spots_remaining
        }
      end
    end
  end
end
