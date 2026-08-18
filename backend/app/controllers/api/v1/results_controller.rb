module Api
  module V1
    class ResultsController < BaseController
      # Public — no auth — same as EventsController#show. Everything else on
      # this controller is organizer-only.
      before_action :authenticate_user!, except: [ :index ]

      MAX_IMPORT_FILE_SIZE = 2.megabytes

      # GET /api/v1/events/:event_id/results — public leaderboard. Empty
      # groups (nothing recorded yet) are still returned rather than 404ing
      # — see Results::BuildLeaderboard's class comment for why that's the
      # frontend's signal to hide the results section rather than a
      # category-based check.
      def index
        event = Event.kept.find(params[:event_id])
        render json: { groups: Results::BuildLeaderboard.call(event: event) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # PATCH /api/v1/registrations/:id/result — organizer sets/updates/clears
      # one participant's finish time by hand. finish_time_seconds: null
      # clears a mistaken entry rather than deleting the Result row outright
      # (keeps this idempotent and simple; an empty Result is harmless).
      def update
        registration = Registration.find(params[:id])
        event = registration.event

        unless event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        validate_params_with_schema(ResultUpdateRequestSchema) do |validated_params|
          result = Result.find_or_initialize_by(registration: registration)
          if result.update(validated_params[:result])
            render json: { result: result_json(result) }
          else
            render json: { error: result.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      # POST /api/v1/events/:event_id/results/import — bulk-set finish times
      # from a CSV (email,finish_time). See Results::ImportCsv for the
      # per-row parsing/matching and why a bad row doesn't abort the rest.
      def import
        event = current_user.events.find(params[:event_id])
        file = params[:file]

        unless file.is_a?(ActionDispatch::Http::UploadedFile)
          render json: { error: "No file provided" }, status: :bad_request
          return
        end

        if file.size > MAX_IMPORT_FILE_SIZE
          render json: { error: "File too large (max #{MAX_IMPORT_FILE_SIZE / 1.megabyte} MB)" }, status: :unprocessable_entity
          return
        end

        summary = Results::ImportCsv.call(event: event, csv_text: file.read)
        render json: summary
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      rescue CSV::MalformedCSVError => e
        render json: { error: "Could not parse CSV: #{e.message}" }, status: :unprocessable_entity
      end

      private

      def result_json(result)
        {
          id: result.id,
          registration_id: result.registration_id,
          finish_time_seconds: result.finish_time_seconds
        }
      end
    end
  end
end
