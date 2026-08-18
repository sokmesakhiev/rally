module Api
  module V1
    class WaitlistEntriesController < BaseController
      before_action :authenticate_user!
      before_action :set_event, only: [ :create, :event_waitlist ]

      # WaitlistEntry error codes that mean "you can't join this waitlist" —
      # mirrors RegistrationsController::FULL_ERROR_CODES, but inverted: here
      # :not_full means the event/type ISN'T actually full, so the frontend
      # should point the user at the normal register flow instead.
      ALREADY_REGISTERED_CODE = :already_registered
      NOT_FULL_CODE = :not_full

      # GET /api/v1/waitlist_entries — current user's own active waitlist spots
      def index
        entries = current_user.waitlist_entries
          .waiting
          .includes(:event)
          .order(created_at: :asc)

        render json: { waitlist_entries: entries.map { |e| entry_json(e, include_event: true) } }
      end

      # GET /api/v1/events/:event_id/waitlist_entries — organizer view
      def event_waitlist
        unless @event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        entries = @event.waitlist_entries.waiting.includes(user: :profile).order(created_at: :asc)
        render json: {
          waitlist_entries: entries.each_with_index.map { |e, i| entry_json(e, include_profile: true, position: i + 1) }
        }
      end

      # POST /api/v1/events/:event_id/waitlist_entries
      def create
        validate_params_with_schema(WaitlistEntryCreateRequestSchema) do |validated_params|
          entry = current_user.waitlist_entries.create!(
            event: @event,
            event_type_ids: validated_params[:event_type_ids] || [],
            status: "waiting"
          )

          render json: { waitlist_entry: entry_json(entry) }, status: :created
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: waitlist_error_json(e.record), status: :unprocessable_entity
      end

      # DELETE /api/v1/waitlist_entries/:id — leave the waitlist
      def destroy
        entry = current_user.waitlist_entries.find(params[:id])
        entry.update!(status: "cancelled")
        render json: { message: "Removed from waitlist" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Waitlist entry not found" }, status: :not_found
      end

      private

      def set_event
        @event = Event.kept.includes(:event_types).find(params[:event_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # Builds a clean { error:, code: } payload, same shape as
      # RegistrationsController#capacity_error_json, so the frontend can
      # branch on `code` instead of string-matching the message.
      def waitlist_error_json(record)
        details = record.errors.details[:base] || []
        code =
          if details.any? { |d| d[:error] == ALREADY_REGISTERED_CODE }
            "already_registered"
          elsif details.any? { |d| d[:error] == NOT_FULL_CODE }
            "not_full"
          end
        { error: record.errors.full_messages.join(", "), code: code }.compact
      end

      def entry_json(entry, include_event: false, include_profile: false, position: nil)
        json = {
          id: entry.id,
          event_id: entry.event_id,
          user_id: entry.user_id,
          event_type_ids: entry.event_type_ids,
          status: entry.status,
          created_at: entry.created_at
        }
        json[:position] = position if position

        if include_event
          json[:event] = {
            id: entry.event.id,
            title: entry.event.title,
            start_at: entry.event.start_at
          }
        end

        if include_profile
          json[:email] = entry.user.email
          json[:profile] = {
            display_name: entry.user.profile&.display_name,
            avatar_url: entry.user.profile&.avatar_url
          }
        end

        json
      end
    end
  end
end
