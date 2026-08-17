module Api
  module V1
    class RegistrationsController < BaseController
      before_action :authenticate_user!
      before_action :set_event, only: [ :create ]

      # Registration/RegistrationEventType error codes that mean "this event
      # (or event type) has reached capacity" — see
      # Registration#event_not_full and RegistrationEventType#event_type_not_full.
      FULL_ERROR_CODES = [ :event_full, :event_type_full ].freeze

      # GET /api/v1/registrations — current user's registrations with event data
      def index
        registrations = current_user.registrations
          .includes(:certificate, :result, event: :registrations, event_types: [])
          .order(created_at: :desc)

        render json: {
          registrations: registrations.map { |r| registration_json(r, include_event: true, include_types: true) }
        }
      end

      # GET /api/v1/events/:event_id/registrations — organizer view of participants
      def event_registrations
        event = current_user.events.find(params[:event_id])
        regs = event.registrations.kept
          .includes({ user: :profile }, :event_types, :certificate, :result)
          .order(created_at: :asc)

        render json: {
          registrations: regs.map { |r| registration_json(r, include_profile: true, include_types: true) }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # POST /api/v1/events/:event_id/registrations
      # Accepts:
      #   answers:        [{ survey_question_id, answer_text?, answer_options? }]
      #   event_type_ids: ["uuid", ...]
      def create
        validate_params_with_schema(RegistrationCreateRequestSchema) do |validated_params|
          if current_user.registrations.exists?(event_id: @event.id)
            render json: { error: "Already registered" }, status: :unprocessable_entity
            return
          end

          Registration.transaction do
            # Calculate amount from selected types (or fall back to event price)
            amount = compute_amount(@event, validated_params[:event_type_ids])

            registration = current_user.registrations.create!(
              event: @event,
              status: "confirmed",
              payment_status: amount == 0 ? "paid" : "unpaid",
              amount_paid_cents: 0
            )

            # Wire up event types
            if validated_params[:event_type_ids].present?
              Array(validated_params[:event_type_ids]).each do |type_id|
                registration.registration_event_types.create!(event_type_id: type_id)
              end
            end

            # Wire up survey answers
            if @event.survey_id.present? && validated_params[:answers].present?
              validated_params[:answers].each do |ans|
                registration.registration_answers.create!(
                  survey_question_id: ans[:survey_question_id],
                  answer_text:        ans[:answer_text].presence,
                  answer_options:     ans[:answer_options] || []
                )
              end
            end

            RegistrationMailer.confirmation(registration).deliver_later

            render json: { registration: registration_json(registration, include_types: true) }, status: :created
          end
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: capacity_error_json(e.record), status: :unprocessable_entity
      end

      # PATCH /api/v1/registrations/:id — organizer updates payment status
      def update
        registration = Registration.find(params[:id])
        event = registration.event

        unless event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        validate_params_with_schema(RegistrationUpdateRequestSchema) do |validated_params|
          if registration.update(validated_params[:registration])
            render json: { registration: registration_json(registration, include_profile: true, include_types: true) }
          else
            render json: { error: registration.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      # DELETE /api/v1/registrations/:id — organizer removes participant.
      # Soft-delete (see Registration#discard!) — the Payment/Refund history
      # (if any) stays intact rather than being wiped out.
      def destroy
        registration = Registration.find(params[:id])
        event = registration.event

        unless event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        registration.discard!
        # Removing a participant may have freed a spot (event- or
        # type-level) — offer it to whoever's been waiting longest. See
        # Waitlists::PromoteNext; Refunds::IssueRefund calls this too.
        Waitlists::PromoteNext.call(event)
        render json: { message: "Participant removed" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      # POST /api/v1/registrations/:id/check_in — organizer scans the
      # attendee's ticket QR (which just encodes this id) or taps them in
      # from the manual list. Idempotent: re-scanning an already-checked-in
      # badge doesn't error or bump the timestamp, it just reports
      # `already_checked_in: true` so the scanner UI can show "already in"
      # instead of a fresh success state.
      def check_in
        registration = Registration.find(params[:id])
        event = registration.event

        unless event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        already_checked_in = registration.checked_in?
        registration.update!(checked_in_at: Time.current) unless already_checked_in

        render json: {
          registration: registration_json(registration, include_profile: true, include_types: true),
          already_checked_in: already_checked_in
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      # DELETE /api/v1/registrations/:id/check_in — undo a mis-scan/mis-tap.
      def undo_check_in
        registration = Registration.find(params[:id])
        event = registration.event

        unless event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        registration.update!(checked_in_at: nil)
        render json: { registration: registration_json(registration, include_profile: true, include_types: true) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      private

      def set_event
        @event = Event.kept.includes(:event_types).find(params[:event_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # Builds a clean { error:, code: } payload for a failed registration.
      # Uses the record's own error messages instead of RecordInvalid#message
      # (which prepends an ugly "Validation failed: " string), and surfaces a
      # machine-readable `code: "full"` when the failure was a capacity
      # validation (Registration#event_not_full / RegistrationEventType#
      # event_type_not_full — see their :event_full / :event_type_full error
      # codes) so the frontend can react distinctly instead of string-matching.
      def capacity_error_json(record)
        details = record.errors.details[:base] || []
        is_full = details.any? { |d| FULL_ERROR_CODES.include?(d[:error]) }
        { error: record.errors.full_messages.join(", "), code: is_full ? "full" : nil }.compact
      end

      # Sum the effective price of each selected type; fall back to event price if no types
      def compute_amount(event, type_ids)
        ids = Array(type_ids).compact.reject(&:empty?)
        return event.price_cents if ids.empty? || event.event_types.empty?

        types = event.event_types.select { |t| ids.include?(t.id) }
        types.sum(&:effective_price_cents)
      end

      def registration_json(reg, include_event: false, include_profile: false, include_types: false)
        json = {
          id: reg.id,
          event_id: reg.event_id,
          user_id: reg.user_id,
          status: reg.status,
          payment_status: reg.payment_status,
          amount_paid_cents: reg.amount_paid_cents,
          created_at: reg.created_at,
          checked_in_at: reg.checked_in_at
        }

        # nil until an organizer (via Api::V1::ResultsController) records
        # one — most event types (a social gathering, a no-timing group
        # ride) simply never get a Result row at all.
        if reg.result&.finish_time_seconds.present?
          json[:finish_time_seconds] = reg.result.finish_time_seconds
        end

        if include_event && reg.association(:event).loaded?
          json[:event] = {
            id:           reg.event.id,
            title:        reg.event.title,
            description:  reg.event.description,
            category:     reg.event.category,
            location:     reg.event.location,
            start_at:     reg.event.start_at,
            end_at:       reg.event.end_at,
            capacity:     reg.event.capacity,
            price_cents:  reg.event.price_cents,
            currency:     reg.event.currency,
            is_published: reg.event.is_published,
            brand_color:  reg.event.brand_color,
            banner_url:   reg.event.banner_url,
            logo_url:     reg.event.logo_url
          }
        end

        if include_profile && reg.user&.profile
          json[:profile] = {
            display_name: reg.user.profile.display_name,
            avatar_url:   reg.user.profile.avatar_url
          }
        end

        if include_types
          types = reg.association(:event_types).loaded? ? reg.event_types : reg.event_types.to_a
          json[:event_types] = types.map do |t|
            { id: t.id, name: t.name, price_cents: t.price_cents, position: t.position }
          end
        end

        # nil until GenerateCertificatesJob (via Certificates::RenderPdf) has
        # actually rendered one — see that job's class comment for what
        # makes a registration eligible in the first place. file_url is
        # already a full URL (set by RenderPdf via
        # ActiveStorage::Blob.create_and_upload!), so no url_for needed here.
        if reg.certificate&.file_present?
          json[:certificate_url] = reg.certificate.file_url
        end

        json
      end
    end
  end
end
