module Api
  module V1
    class EventsController < BaseController
      before_action :authenticate_user!, only: [ :create, :update, :destroy, :my_events, :unpublish, :activity ]
      # #show stays public (no bare authenticate_user!) — anyone can view a
      # published event page without an account. This just populates
      # current_user *when* a valid, live token is present, so event_role_for
      # can tell the frontend "owner"/"manager"/etc. for the manage-event
      # page's role-aware chrome (see event-membership-tickets.md, Ticket G)
      # without gating the endpoint itself. Uses identify_current_user!, not
      # authenticate_user_optional! — the latter deliberately still errors
      # for a suspended/deleted account's token (right for guest checkout,
      # where that's a real action being blocked), which would wrongly turn
      # "browsing a public event page" into a 403/401 for anyone whose
      # account status changed after their browser last got a fresh token.
      # current_user simply stays nil for an anonymous viewer or a
      # suspended/deleted one, same as before this field existed.
      before_action :identify_current_user!, only: [ :show ]
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

          # publicly_visible, not published.kept — see Ticket J (#339). A
          # suspended organization's events keep is_published: true (the
          # cascade derives rather than writes, so unsuspending restores
          # them), so bare `.published` would serve them to the public.
          scope = Event.publicly_visible.upcoming
            .search(validated_params[:q])
            .in_category(validated_params[:category])

          # Count before paginating, and off the eager-loaded relation — a
          # COUNT with includes() would build a needless join.
          total = scope.count

          events = scope
            # organization: :owner is preloaded because event_json calls
            # #suspended?, which since Ticket J (#339) walks
            # event → organization → owner — two extra queries per row
            # without this.
            .includes({ organization: :owner },
                      event_types: { registration_event_types: :registration })
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

      # GET /api/v1/events/my — events the current user helps run: the ones
      # they created, plus (issue #278) the ones they've joined as a member.
      # Without the latter, an invited member accepts and then has no way to
      # reach the event at all. This is a listing scope, not a gate — there's
      # no "may I?" decision to centralize, so it stays outside
      # EventAuthorization's #authorize_event!/#find_authorized_event!.
      #
      # Each event is tagged with the caller's `role` so the dashboard can
      # render "Owner"/"Manager"/etc. and hide actions the role lacks (see
      # event-membership-tickets.md, Ticket G). Creator status wins if
      # somehow both apply (mirrors EventAuthorization#event_role_for
      # preferring :owner over any membership row the creator might also
      # hold) — an event can only be tagged once per response.
      def my_events
        # organization: :owner for the same reason as events#index — event_json
        # calls #suspended?, which walks event → organization → owner.
        eager_load = [ :registrations, { organization: :owner },
                       { event_types: { registration_event_types: :registration } } ]

        owned = current_user.events.kept.includes(*eager_load)
        # Events presented by an organization this user owns or administers,
        # including ones a colleague created — see Ticket C (#332). These
        # count as "owner" for the same reason EventAuthorization resolves
        # them that way.
        org_events = Event.kept
          .where(organization_id: current_user.administered_organizations.select(:id))
          .includes(*eager_load)
        member_rows = current_user.event_memberships
          .joins(:event).merge(Event.kept)
          .includes(event: eager_load)

        # Insertion order matters: the strongest relationship wins, and each
        # branch skips events an earlier one already claimed, so someone who
        # is both an org admin and a check-in member sees "owner", not
        # "check_in" — and never sees the same event twice.
        events_by_id = {}
        owned.each { |e| events_by_id[e.id] = [ e, "owner" ] }
        org_events.each { |e| events_by_id[e.id] ||= [ e, "owner" ] }
        member_rows.each do |membership|
          next if events_by_id.key?(membership.event_id)
          events_by_id[membership.event_id] = [ membership.event, membership.role ]
        end

        events = events_by_id.values.sort_by { |(e, _role)| e.start_at }

        render json: {
          events: events.map { |e, role|
            # Ruby-side filter, not e.registrations.active.size — .active is a
            # `where`, which would force a fresh query per event instead of
            # using the already-preloaded array above.
            active_count = e.registrations.count { |r| r.status != "cancelled" }
            event_json(e, include_types: true).merge(registrations_count: active_count, role: role)
          }
        }
      end

      # GET /api/v1/events/:id
      def show
        # organization: :owner is preloaded because event_json calls
        # #suspended?, which since Ticket J (#339) walks
        # event → organization → owner.
        @event = Event.includes(:registrations, { organization: :owner },
                                 survey: :survey_questions,
                                 event_types: { registration_event_types: :registration })
          .find(params[:id])
        json = event_json(@event, include_count: true, include_survey: true, include_types: true)
        # Same "owner"/EventMembership::ROLES/nil shape as events#my_events'
        # per-event `role` tag — nil here just means "no relationship with
        # this event" (an anonymous viewer, or a signed-in stranger), not an
        # error. See EventAuthorization#event_role_for.
        json[:role] = event_role_for(@event)
        render json: { event: json }
      end

      # POST /api/v1/events
      def create
        validate_params_with_schema(EventRequestSchema) do |validated_params|
          attrs = validated_params[:event]
          organization = resolve_organization_for_create!(attrs[:organization_id])
          next if organization.nil?

          event = current_user.events.new(attrs.except(:organization_id))
          event.organization = organization

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
        event = find_authorized_event!(params[:id], :view_activity, scope: Event.kept)
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

      # One before_action covering three actions with three different
      # capabilities — see EventAuthorization::CAPABILITIES. All three are
      # owner-only today and stay that way even once roles land (they either
      # destroy work that isn't the actor's or spend the owner's money), but
      # naming them separately means that's a stated decision rather than an
      # accident of them sharing a filter.
      ACTION_CAPABILITIES = {
        "update" => :update_event,
        "destroy" => :delete_event,
        "unpublish" => :unpublish_event
      }.freeze

      def authorize_creator!
        authorize_event!(@event, ACTION_CAPABILITIES.fetch(action_name))
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
      # Resolves the organization a new event will be presented by, or renders
      # and returns nil when it can't.
      #
      # When organization_id is given it is authoritative and never
      # second-guessed: a user may administer several organizations (see
      # organization-identity-tickets.md's Ticket A), so inferring one would
      # eventually publish an event under the wrong brand — precisely the
      # failure this feature exists to prevent.
      #
      # 404, not 403, for an organization the caller may not use: the same
      # "don't confirm it exists" reasoning the admin namespace uses.
      #
      # ── TRANSITIONAL, remove with Ticket G (#336) ────────────────────────
      # Everything below the `if organization_id.present?` branch exists only
      # because the frontend doesn't send organization_id until #336 adds the
      # org selector. Without it, merging #332 would break event creation for
      # every user until #336 ships — a sustained outage of the core feature,
      # not just a deploy-window blip.
      #
      # When #336 lands: delete the fallback, and make organization_id
      # required again in EventRequestSchema.
      def resolve_organization_for_create!(organization_id)
        if organization_id.present?
          organization = Organization.kept.find_by(id: organization_id)
          return organization if organization&.administered_by?(current_user)

          render json: {
            error: "Organization not found",
            code: "organization_not_found"
          }, status: :not_found
          return nil
        end

        implicit_organization_for_create!
      end

      # TRANSITIONAL — see #resolve_organization_for_create!.
      def implicit_organization_for_create!
        candidates = current_user.administered_organizations.kept.to_a

        case candidates.length
        when 1
          candidates.first
        when 0
          # A user who has never organized anything has no organization: the
          # #330 backfill only covered people who already had events. Create
          # one from their profile, mirroring that backfill, so signing up and
          # creating a first event still works end to end. #336 replaces this
          # with an explicit "create your organization" step.
          create_implicit_organization!
        else
          # Genuinely ambiguous, so refuse rather than guess. Only reachable
          # once someone has a second organization, which needs #333's API —
          # by which point #336 should be sending the id explicitly anyway.
          render json: {
            error: "You administer more than one organization. Say which one is presenting this event.",
            code: "organization_required"
          }, status: :unprocessable_entity
          nil
        end
      end

      # TRANSITIONAL — see #resolve_organization_for_create!.
      def create_implicit_organization!
        name = current_user.profile&.display_name.presence ||
               current_user.email.to_s.split("@").first.presence ||
               "Organizer"

        Organization.create!(owner: current_user, name: name)
      end

      # Returns true (and renders) when the request must be rejected, so
      # callers can `next if reject_unverified_paid_event!(...)`.
      #
      # Gated on the ORGANIZATION since Ticket I (#338), not the signed-in
      # user. Verification is a claim about who takes the money, and since
      # #331 registration payments settle into the organization's own PayWay
      # account — so a verified individual creating an event under an
      # unverified club must not be able to charge for it.
      #
      # Existing organizers didn't lose access when this moved: the #338
      # backfill carried each verified owner's status onto the organizations
      # they own. A newly created organization does start unverified, which
      # is the intended behaviour — staff vouch for each brand that takes
      # payments, not once per person.
      def reject_unverified_paid_event!(event, was_paid:)
        return false if was_paid
        return false unless event.paid?
        return false if event.organization&.verified?

        render json: {
          error: "This organization needs to be verified before it can run a paid event. " \
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
          organization_id: event.organization_id,
          # Just enough to render the "Presented by" block and link through to
          # the organizer page (Ticket H, #337) — the full public profile,
          # including trust signals and their other events, is the organizers
          # endpoint. Safe on a public payload: every field here already
          # appears on that page.
          organization: event.organization && {
            slug: event.organization.slug,
            name: event.organization.name,
            logo_url: event.organization.logo_url,
            verified: event.organization.verified?
          },
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
          suspended: event.suspended?,
          suspension_reason: event.suspension_reason,
          suspended_at: event.suspended_at,
          # nil | "event" | "organization" — lets the UI say *why* this is
          # unavailable, since since Ticket J (#339) an event can be suspended
          # because its organizer was, not only on its own merits.
          # suspension_reason/suspended_at stay the event's own values and are
          # nil for an inherited suspension.
          suspension_source: event.suspension_source,
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
