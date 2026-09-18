# frozen_string_literal: true

module Api
  module V1
    module Admin
      # The moderation queue: what people have reported, grouped so a reviewer
      # sees one row per event rather than one per report.
      #
      # **Not `ReportsController`** — that name is already taken in this
      # namespace by the analytics dashboard (events over time, revenue). Two
      # unrelated things called "reports" is a collision waiting to happen, so
      # this one carries the longer name.
      #
      # Inherits Admin::BaseController, so authenticate_user! + require_admin!
      # (404, not 403) are the whole authorization story.
      class EventReportsController < BaseController
        # How many individual reports #show returns for one event. Past this
        # the list stops informing the decision and starts being a payload.
        DETAIL_LIMIT = 200

        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Report not found" }, status: :not_found
        end

        # GET /api/v1/admin/event_reports
        #
        # Grouped by event on purpose. A reviewer's unit of work is "should
        # this event stay up", not "what did reporter #7 say" — and an event
        # with twelve reports is one decision, not twelve. The count comes back
        # per event and drives priority.
        def index
          validate_params_with_schema(AdminEventReportIndexRequestSchema) do |query|
            page = query[:page] || 1
            per_page = query[:per_page] || AdminEventReportIndexRequestSchema::DEFAULT_PER_PAGE

            scope = filtered(query)

            # Count distinct events, not rows — the list is one row per event,
            # so a row-count total would overstate the number of pages and
            # offer pages that don't exist.
            total = scope.distinct.count(:event_id)

            events = grouped_events(scope, page: page, per_page: per_page)

            render json: {
              reports: events,
              meta: {
                page: page,
                per_page: per_page,
                total_count: total,
                total_pages: (total.to_f / per_page).ceil
              },
              # Independent of the active filter, same as the support inbox's
              # awaiting_count: it means "how much is waiting on us", not "how
              # many rows are on screen".
              open_count: EventReport.live.distinct.count(:event_id)
            }
          end
        end

        # GET /api/v1/admin/event_reports/events/:event_id
        #
        # The reports on one event, with what the reviewer needs to decide:
        # the reports themselves, and the event's current state.
        #
        # Deliberately unfiltered, unlike #index — a reviewer deciding whether
        # an event stays up wants everything said about it, not the slice that
        # matched the filter they happened to arrive through.
        #
        # Capped at DETAIL_LIMIT because an event can be brigaded and nobody
        # reads the two-thousandth copy of the same complaint. `total_count`
        # tells the reviewer what's behind the cap, so a truncated list can't
        # be mistaken for the whole story.
        def show
          event = Event.find(params[:event_id])
          all = event.event_reports
          reports = all.includes(:reporter, :reviewed_by).newest_first.limit(DETAIL_LIMIT)

          render json: {
            event: event_summary(event),
            reports: reports.map { |r| report_json(r) },
            total_count: all.count
          }
        end

        # POST /api/v1/admin/event_reports/events/:event_id/resolve
        #
        # Closes **every** live report on the event in one action, because the
        # decision was about the event. Resolving them one at a time would let
        # an event sit half-reviewed, which reads in the queue as "still needs
        # work" when it doesn't.
        #
        # Deliberately does NOT suspend or unpublish anything. Those are
        # separate, already-existing admin actions (Admin::EventsController)
        # with their own audit entries — a reviewer decides to take an event
        # down as its own act, so the record shows who did it and that it was
        # chosen rather than implied by closing a ticket.
        def resolve
          event = Event.find(params[:event_id])
          status = params[:status].to_s
          unless [ EventReport::ACTIONED, EventReport::DISMISSED ].include?(status)
            render json: { error: "status must be actioned or dismissed" },
                   status: :unprocessable_entity
            return
          end

          # One UPDATE, not one per report. `EventReport#resolve!` is the same
          # write for a single row and stays the model's API; here the row
          # count is whatever the internet decided to send, so a brigaded event
          # would otherwise mean thousands of round trips inside one request.
          # Every column set is a plain attribute with no callbacks behind it,
          # which is what makes the set-based version equivalent rather than
          # merely faster.
          resolved = event.event_reports.live.update_all(
            status: status,
            reviewed_by_id: current_user.id,
            reviewed_at: Time.current,
            reviewer_note: params[:note].presence,
            updated_at: Time.current
          )

          log_admin_action("resolve_event_reports", event)

          render json: { resolved: resolved, status: status }
        end

        private

        def filtered(query)
          scope = EventReport.all
          # Default to the worklist, not the archive.
          scope = if query[:status].present?
                    scope.where(status: query[:status])
          else
                    scope.live
          end
          scope = scope.where(reason: query[:reason]) if query[:reason].present?
          scope
        end

        # Counts are aggregated in SQL rather than by loading the reports and
        # counting them in Ruby. An event that gets brigaded is exactly the
        # event a reviewer opens this page to find, and loading every one of
        # its reports to produce a number would make the queue slowest at the
        # moment it matters most.
        #
        # **The per-row figures describe the rows the filter selected**, not
        # every report on the event — otherwise `?reason=gambling` would show a
        # row whose count and reason tally contradict the list it sits in.
        # `open_count` is the deliberate exception: it is every live report on
        # the event whatever the filter says, because it answers "is there work
        # left here", which is a fact about the event rather than about the
        # current view. `priority` follows it for the same reason — an event
        # with twelve open reports must not read as "normal" just because
        # someone filtered to one reason.
        def grouped_events(scope, page:, per_page:)
          event_ids = scope.group(:event_id)
            .order(Arel.sql("MAX(event_reports.created_at) DESC"))
            .limit(per_page)
            .offset((page - 1) * per_page)
            .pluck(:event_id)

          return [] if event_ids.empty?

          matching = scope.where(event_id: event_ids)
          totals = matching.group(:event_id).count
          last_reported = matching.group(:event_id).maximum(:created_at)
          reasons = reason_tallies(matching)
          live_counts = EventReport.live.where(event_id: event_ids).group(:event_id).count

          events = Event.where(id: event_ids).includes(:organization).index_by(&:id)

          # Preserve the id order from the grouped query — `Event.where(id:)`
          # returns rows in whatever order Postgres likes, which would scramble
          # the newest-activity-first sort the reviewer is relying on.
          event_ids.filter_map do |id|
            event = events[id]
            next unless event

            live_count = live_counts[id] || 0

            {
              event: event_summary(event),
              report_count: totals[id] || 0,
              open_count: live_count,
              priority: EventReport.priority_for(live_count),
              reasons: reasons[id] || {},
              last_reported_at: last_reported[id]
            }
          end
        end

        # `group(:event_id, :reason).count` returns one flat hash keyed by
        # [event_id, reason]; the response wants one hash per event.
        def reason_tallies(matching)
          matching.group(:event_id, :reason).count.each_with_object({}) do |((id, reason), n), acc|
            (acc[id] ||= {})[reason] = n
          end
        end

        def event_summary(event)
          {
            id: event.id,
            title: event.title,
            description: event.description,
            category: event.category,
            location: event.location,
            start_at: event.start_at,
            is_published: event.is_published,
            visibility: event.visibility,
            suspended: event.suspended?,
            suspension_reason: event.suspension_reason,
            organization: event.organization && {
              slug: event.organization.slug,
              name: event.organization.name
            }
          }
        end

        def report_json(report)
          {
            id: report.id,
            reason: report.reason,
            details: report.details,
            status: report.status,
            created_at: report.created_at,
            # Nil for an anonymous report, which is a normal state rather than
            # missing data — the frontend renders it as "Anonymous".
            reporter: report.reporter && {
              id: report.reporter.id,
              email: report.reporter.email
            },
            reviewed_by: report.reviewed_by&.email,
            reviewed_at: report.reviewed_at,
            reviewer_note: report.reviewer_note
          }
        end
      end
    end
  end
end
