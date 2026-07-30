module Api
  module V1
    class EventsController < BaseController
      before_action :authenticate_user!, only: [ :create, :update, :destroy, :my_events, :unpublish ]
      before_action :set_event, only: [ :show, :update, :destroy, :unpublish ]
      before_action :authorize_creator!, only: [ :update, :destroy, :unpublish ]

      # GET /api/v1/events — public, published, upcoming
      def index
        events = Event.published.upcoming.includes(:event_types).order(start_at: :asc)
        render json: { events: events.map { |e| event_json(e, include_types: true) } }
      end

      # GET /api/v1/events/my — current user's created events
      def my_events
        events = current_user.events.includes(:registrations, :event_types).order(start_at: :asc)
        render json: {
          events: events.map { |e|
            event_json(e, include_types: true).merge(registrations_count: e.registrations.size)
          }
        }
      end

      # GET /api/v1/events/:id
      def show
        @event = Event.includes(survey: :survey_questions, event_types: []).find(params[:id])
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
            render json: { event: event_json(@event, include_types: true) }
          else
            render json: { error: @event.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      end

      # DELETE /api/v1/events/:id
      def destroy
        @event.destroy!
        render json: { message: "Event deleted" }
      end

      # POST /api/v1/events/:id/unpublish
      # Takes an event down without affecting its paid plan — republishing
      # under the same plan later is free (see EventPlanPaymentsController).
      def unpublish
        @event.update!(is_published: false)
        render json: { event: event_json(@event, include_types: true) }
      end

      private

      def set_event
        @event = Event.find(params[:id])
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
          created_at: event.created_at,
          updated_at: event.updated_at
        }
        json[:registrations_count] = event.registrations.size if include_count
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
