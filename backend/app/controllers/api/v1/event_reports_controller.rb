# frozen_string_literal: true

module Api
  module V1
    # Participant-facing intake. The staff side lives under
    # Api::V1::Admin::EventReportsController — a different base class, so a
    # queue endpoint can't become publicly reachable just by sitting in the
    # wrong file (same split as the support chat's two controllers).
    #
    # Note the name: Api::V1::Admin::ReportsController already exists and is
    # *analytics* (events over time, revenue). These are event reports, and
    # the longer name is what keeps the two apart.
    class EventReportsController < BaseController
      # Optional auth, not required. A signed-in report carries a reporter, so
      # repeat bad-faith reporters are visible and the reviewer has someone to
      # ask; an anonymous one is still accepted, because the person best placed
      # to report a gathering they're frightened of may not want an account
      # attached to it, and requiring one filters out exactly the reports worth
      # having. Rate limits do the work an account would otherwise do — see
      # `event_reports/*` in config/initializers/rack_attack.rb.
      before_action :authenticate_user_optional!
      before_action :set_event

      # POST /api/v1/events/:event_id/reports
      def create
        validate_params_with_schema(EventReportRequestSchema) do |validated_params|
          report = @event.event_reports.new(
            validated_params[:report].merge(reporter: current_user)
          )

          if save_report(report)
            Notifications::ModerationNotifier.event_reported(@event)

            # Deliberately the same response whether this is the first report
            # or the tenth, and whether the event is already suspended. The
            # reporter learns nothing about Rally's moderation state from
            # reporting — otherwise the endpoint becomes an oracle for probing
            # which events are under review.
            render json: { message: "Thanks — our team will review this event." }, status: :created
          elsif already_reported?(report)
            # Not an error worth showing as one: the person already told us.
            # Same message as success, for the same no-oracle reason.
            render json: { message: "Thanks — our team will review this event." }, status: :created
          else
            render json: { error: report.errors.full_messages.join(", ") },
                   status: :unprocessable_entity
          end
        end
      end

      private

      # The uniqueness validation and the partial unique index are the same
      # rule in two places, and which one stops a duplicate depends on how a
      # race lands: the validation does its own SELECT, so the usual loser gets
      # a validation error, while a caller whose SELECT ran before the winner's
      # INSERT committed is stopped by the index instead. Handling only the
      # first leaves a rare 500 on the one path that must never leak anything —
      # a stack trace is an oracle too, and it is the *duplicate* reporter who
      # would see it. Same pairing as `Conversations::Start`.
      #
      # The INSERT gets its own savepoint so a unique violation doesn't abort
      # an enclosing transaction and turn the caller's next query into
      # PG::InFailedSqlTransaction.
      def save_report(report)
        ActiveRecord::Base.transaction(requires_new: true) { report.save }
      rescue ActiveRecord::RecordNotUnique
        report.errors.add(:event_id, :taken, message: "has already been reported by you")
        false
      end

      def already_reported?(report)
        report.errors.of_kind?(:event_id, :taken)
      end

      # `Event.kept` only — a soft-deleted event isn't visible to report, and
      # 404 rather than a distinct error so this can't be used to enumerate
      # which ids exist.
      def set_event
        @event = Event.kept.find(params[:event_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end
    end
  end
end
