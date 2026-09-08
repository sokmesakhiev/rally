module Api
  module V1
    class RegistrationsController < BaseController
      # #create serves both signed-in participants and anonymous guest
      # checkout — see authenticate_user_optional! and
      # Registrations::GuestCheckout. Every other action still requires a
      # real session.
      before_action :authenticate_user!, except: [ :create ]
      before_action :authenticate_user_optional!, only: [ :create ]
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
        event = find_authorized_event!(params[:event_id], :view_participants)
        regs = event.registrations.kept
          .includes({ user: :profile }, :event_types, :certificate, :result)
          .order(created_at: :asc)

        render json: {
          registrations: regs.map { |r| registration_json(r, include_profile: true, include_types: true) }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # GET /api/v1/events/:event_id/registrations/export — CSV download for
      # offline use (check-in sheets, mail merges). Same authorization and
      # ordering as #event_registrations (organizer only; non-organizers get
      # a 404, not a 403, same privacy-through-obscurity as everywhere else
      # in this controller) — see Registrations::ExportCsv for column
      # details.
      def export
        event = find_authorized_event!(params[:event_id], :export_participants)
        csv = Registrations::ExportCsv.call(event: event)

        send_data csv,
          filename: export_filename(event),
          type: "text/csv",
          disposition: "attachment"
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # POST /api/v1/events/:event_id/registrations
      # Accepts:
      #   answers:        [{ survey_question_id, answer_text?, answer_options? }]
      #   event_type_ids: ["uuid", ...]
      #   guest:          { name, email?, phone? } — required when there's no
      #                   signed-in user (see authenticate_user_optional!),
      #                   ignored otherwise. At least one of email/phone is
      #                   required — phone-only is a first-class path, most
      #                   common contact channel in Cambodia (see
      #                   Registrations::GuestCheckout).
      def create
        validate_params_with_schema(RegistrationCreateRequestSchema) do |validated_params|
          is_guest = current_user.nil?
          guest_params = validated_params[:guest]

          if is_guest && guest_params.blank?
            render json: {
              error: "Sign in, or provide your name and a phone number or email, to register.",
              code: "guest_info_required"
            }, status: :unprocessable_entity
            return
          end

          if is_guest && guest_params[:email].blank? && guest_params[:phone].blank?
            render json: {
              error: "Provide a phone number or email so we can reach you.",
              code: "contact_required"
            }, status: :unprocessable_entity
            return
          end

          if is_guest
            # Attaches to an existing account when the email/phone matches
            # one, without issuing a session for it — see GuestCheckout's
            # class comment for why this is safe and why sign-in is never
            # forced here.
            checkout = Registrations::GuestCheckout.call(
              email: guest_params[:email],
              phone: guest_params[:phone],
              name: guest_params[:name]
            )
            registrant = checkout.user
            new_guest_account = checkout.newly_created
          else
            registrant = current_user
            new_guest_account = false
          end

          if registrant.registrations.exists?(event_id: @event.id)
            render json: { error: "Already registered" }, status: :unprocessable_entity
            return
          end

          Registration.transaction do
            # Calculate amount from selected types (or fall back to event price)
            amount = compute_amount(@event, validated_params[:event_type_ids])

            registration = registrant.registrations.create!(
              event: @event,
              status: "confirmed",
              payment_status: amount == 0 ? "paid" : "unpaid",
              amount_paid_cents: 0,
              amount_owed_cents: amount
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

            # A phone-only guest's email is a placeholder nobody can read
            # (see GuestCheckout) — sending there would just bounce, so skip
            # it entirely rather than queue a delivery that can't succeed.
            unless registrant.email_auto_generated?
              RegistrationMailer.confirmation(registration, new_guest_account: new_guest_account).deliver_later
            end

            # Outside the email_auto_generated? guard above, deliberately: that
            # guard exists because a phone-only guest's email address is an
            # unreadable placeholder. A push subscription has no such problem —
            # if they have one, it works — so a phone-only guest who enabled
            # notifications should still get this.
            Notifications::RegistrationPush.confirmation(registration)

            # No auth token for a guest registration — see GuestCheckout's
            # class comment. The frontend keeps the guest's own contact info
            # around client-side to authorize the payment step instead (see
            # Api::V1::PaymentsController).
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
        return unless authorize_event!(event, :update_registration)

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
        return unless authorize_event!(event, :remove_participant)

        registration.discard!
        # Snapshot name/email into metadata rather than relying on the
        # association at read time — the participant's own profile can
        # change (or, for a self-deleted account, get anonymized by
        # User#discard!) after this row is written, and the log entry
        # should still read sensibly years later regardless.
        EventActivity.log!(
          event: event,
          actor: current_user,
          action: "remove_participant",
          metadata: {
            registration_id: registration.id,
            participant_name: registration.user.profile&.display_name,
            participant_email: registration.user.email_auto_generated? ? nil : registration.user.email
          }
        )
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
        return unless authorize_event!(event, :check_in)

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
        return unless authorize_event!(event, :check_in)

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

      def export_filename(event)
        slug = event.title.parameterize.presence || "event"
        "#{slug}-registrations-#{Date.current.iso8601}.csv"
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
            avatar_url:   reg.user.profile.avatar_url,
            phone:        reg.user.profile.phone
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
