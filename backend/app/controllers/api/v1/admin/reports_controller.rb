module Api
  module V1
    module Admin
      # Read-only reporting for the admin dashboard: events created over
      # time, participant counts, and Rally's own revenue. Nothing here
      # mutates state, so unlike UsersController/EventsController there's no
      # log_admin_action call.
      class ReportsController < BaseController
        # How many buckets to show per period — chosen so each chart shows a
        # reasonable trend window without the query scanning the entire
        # table history for a fine-grained bucket (12 weeks/months is ~a
        # quarter/year; yearly only needs a handful of buckets since a new
        # one only lands once a year).
        BUCKET_COUNTS = { "week" => 12, "month" => 12, "year" => 6 }.freeze

        # GET /api/v1/admin/reports
        def index
          validate_params_with_schema(AdminReportsIndexRequestSchema) do |validated_params|
            period = validated_params[:period] || "month"

            render json: {
              totals: totals_json,
              events_by_period: bucketed_counts(Event, period),
              platform_revenue_by_period: bucketed_sums(
                EventPlanPayment.where(status: "paid"), period, :amount_cents
              ),
              top_events: top_events_json
            }
          end
        end

        private

        def totals_json
          {
            events_count: Event.count,
            published_events_count: Event.published.count,
            users_count: User.count,
            registrations_count: Registration.count,
            # Always USD — EventPlanPaymentsController hardcodes "usd" since
            # it's Rally's own PayWay account, not an organizer's (see
            # AbaPayway::Client.for_event), so a single sum is safe here
            # unlike registration_volume_by_currency below.
            platform_revenue_cents: EventPlanPayment.where(status: "paid").sum(:amount_cents),
            registration_volume: registration_volume_by_currency
          }
        end

        # Attendee registration payments — money that flows to organizers,
        # not Rally. Shown for context alongside platform_revenue_cents, but
        # kept separate and broken out by currency since Event#currency is
        # organizer-settable (EventUpdateRequestSchema), so summing across
        # currencies would silently mix amounts.
        def registration_volume_by_currency
          Payment.where(status: "approved")
            .group(:currency)
            .sum(:amount_cents)
            .map { |currency, cents| { currency: currency, amount_cents: cents } }
        end

        def top_events_json
          Event
            .left_joins(:registrations)
            .select("events.id, events.title, events.category, events.start_at, " \
                    "COUNT(registrations.id) AS reg_count")
            .group("events.id")
            .order("reg_count DESC, events.created_at DESC")
            .limit(10)
            .map do |event|
              {
                id: event.id,
                title: event.title,
                category: event.category,
                start_at: event.start_at,
                registrations_count: event.attributes["reg_count"].to_i
              }
            end
        end

        # scope: an ActiveRecord relation with a created_at column.
        def bucketed_counts(scope, period)
          raw = scope
            .where("created_at >= ?", window_start(period))
            .group(Arel.sql(date_trunc_sql(period)))
            .count

          by_label = raw.each_with_object({}) { |(bucket, count), h| h[format_bucket(bucket, period)] = count }
          bucket_labels(period).map { |label| { period: label, count: by_label[label] || 0 } }
        end

        def bucketed_sums(scope, period, column)
          raw = scope
            .where("created_at >= ?", window_start(period))
            .group(Arel.sql(date_trunc_sql(period)))
            .sum(column)

          by_label = raw.each_with_object({}) { |(bucket, amount), h| h[format_bucket(bucket, period)] = amount }
          bucket_labels(period).map { |label| { period: label, amount_cents: by_label[label] || 0 } }
        end

        # Builds the date_trunc(...) grouping expression from a fixed
        # allowlist rather than interpolating `period` directly, even though
        # the request schema already restricts it to week/month/year — this
        # keeps the SQL string's only variable input a literal from Ruby
        # source, not request data.
        def date_trunc_sql(period)
          unit =
            case period
            when "week"  then "week"
            when "month" then "month"
            when "year"  then "year"
            else raise ArgumentError, "invalid period: #{period.inspect}"
            end
          "date_trunc('#{unit}', created_at)"
        end

        def window_start(period)
          count = BUCKET_COUNTS.fetch(period)
          case period
          when "week"  then count.weeks.ago.beginning_of_week
          when "month" then count.months.ago.beginning_of_month
          when "year"  then count.years.ago.beginning_of_year
          end
        end

        # The full, gap-filled list of bucket labels for the window — used
        # both to zero-fill periods with no data and to define chart order.
        # Matched against format_bucket(db_value, period) by label string
        # rather than exact timestamp, so the two independently-computed
        # boundaries (Postgres' date_trunc vs Ruby's beginning_of_*) don't
        # need to agree on anything finer than the label itself.
        def bucket_labels(period)
          count = BUCKET_COUNTS.fetch(period)
          now = Time.current
          (0...count).map do |i|
            offset = count - 1 - i
            time =
              case period
              when "week"  then now - offset.weeks
              when "month" then now - offset.months
              when "year"  then now - offset.years
              end
            format_bucket(time, period)
          end
        end

        def format_bucket(time, period)
          case period
          when "week"  then time.beginning_of_week.strftime("%Y-%m-%d")
          when "month" then time.strftime("%Y-%m")
          when "year"  then time.strftime("%Y")
          end
        end
      end
    end
  end
end
