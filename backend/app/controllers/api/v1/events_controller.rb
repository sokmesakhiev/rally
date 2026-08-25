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
          event = current_user.events.new(validated_params[:event])

          # Built unsaved above so the paid-event check runs against what this
          # request would actually produce (including per-type prices) before
          # anything is persisted.
          next if reject_unverified_paid_event!(event, was_paid: false)

          event.save!
          EventMailer.created(event).deliver_later

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
          changes = notifiable_changes(validated_params[:event])

          # Captured before assignment below overwrites it — see
          # #reject_unverified_paid_event! for why only the free → paid
          # *transition* is gated, not every edit to an already-paid event.
          was_paid = @event.paid?
          @event.assign_attributes(validated_params[:event])
          next if reject_unverified_paid_event!(@event, was_paid: was_paid)

          if @event.save
            log_event_details_changes
            NotifyEventDetailsChangedJob.perform_later(@event, changes) if changes.any?

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

      # Only admin-verified organizers may put a price on an event — paid
      # events take real money from participants, so the account behind one
      # has to be someone a human has actually vetted. See User#verified?
      # (deliberately NOT User#email_verified?, which is self-service and so
      # proves nothing) and Admin::UsersController#verify.
      #
      # Gates the free → paid *transition* only, not every edit to an event
      # that's already paid. An organizer who was verified when they created a
      # paid event keeps managing it normally even if their verification is
      # later revoked — their participants have already paid, and breaking
      # that event would punish them, not the organizer. Revocation instead
      # bites on the next attempt to make something new paid. Taking a
      # specific bad event down is Admin::EventsController#unpublish's job,
      # and stopping an organizer outright is User#suspend!'s.
      #
      # Returns true (and renders) when the request must be rejected, so
      # callers can `next if reject_unverified_paid_event!(...)`.
      def reject_unverified_paid_event!(event, was_paid:)
        return false if was_paid
        return false unless event.paid?
        return false if current_user.verified?

        render json: {
          error: "Your account needs to be verified before you can create a paid event. " \
                 "You can publish free events in the meantime.",
          code: "verification_required"
        }, status: :unprocessable_entity
        true
      end

      # Diffs just the fields participants actually care about — price and
      # dates, not branding/description/location — captured *before*
      # @event.update overwrites them, so we still have the old values to
      # compare and to show in the notification email. Returns a hash keyed
      # by field name, each value a { from:, to: } pair of already-cast
      # values (see NotifyEventDetailsChangedJob/RegistrationMailer#details_changed,
      # the sole consumers of this shape); a field absent from `attrs`
      # (not submitted in this PATCH) or unchanged is simply not a key here.
      #
      # start_at/end_at arrive as raw strings (EventUpdateRequestSchema
      # deliberately doesn't coerce them — see its class comment), so they're
      # parsed and compared at second precision rather than as strings, to
      # avoid a false-positive "change" from formatting/sub-second precision
      # differences alone.
      def notifiable_changes(attrs)
        {}.tap do |changes|
          if attrs.key?(:price_cents)
            old_cents = @event.price_cents
            new_cents = attrs[:price_cents]
            changes[:price_cents] = { from: old_cents, to: new_cents } if old_cents != new_cents
          end

          %i[start_at end_at].each do |field|
            next unless attrs.key?(field)

            old_time = @event.public_send(field)
            new_time = attrs[field].present? ? Time.zone.parse(attrs[field]) : nil

            next if old_time.nil? && new_time.nil?
            next if old_time && new_time && old_time.to_i == new_time.to_i

            changes[field] = { from: old_time, to: new_time }
          end
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
