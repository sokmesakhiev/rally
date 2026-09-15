# frozen_string_literal: true

module Registrations
  # Aggregate figures for one event's participant list: how many, how many
  # paid, how much money, how many checked in, and the split across event
  # types.
  #
  # **This exists so the participant list can be paginated.** The manage-event
  # dashboard used to compute all of these in JavaScript by loading every
  # registration and calling `.filter`/`.reduce` over the array. That made
  # pagination impossible to add safely: paginating the list would have left
  # the revenue card summing one page, quietly reporting a fraction of the
  # real figure on a product that takes real money. Aggregates have to come
  # from the database or they can't be trusted once the list is a window.
  #
  # It is also strictly cheaper than what it replaces — a handful of counts
  # over an indexed foreign key instead of serialising every row, its user,
  # its profile, its event types, its certificate and its result.
  class Summary
    Result = Struct.new(
      :total, :paid, :unpaid, :checked_in, :revenue_cents, :by_event_type,
      keyword_init: true
    ) do
      def as_json(*)
        {
          total: total,
          paid: paid,
          unpaid: unpaid,
          checked_in: checked_in,
          revenue_cents: revenue_cents,
          by_event_type: by_event_type
        }
      end
    end

    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      Result.new(
        total: scope.count,
        paid: scope.where(payment_status: "paid").count,
        unpaid: scope.where.not(payment_status: "paid").count,
        checked_in: scope.where.not(checked_in_at: nil).count,
        # COALESCE because SUM over no rows is NULL, not 0 — an event with no
        # registrations would otherwise render "$NaN" rather than "$0.00".
        revenue_cents: scope.sum(:amount_paid_cents).to_i,
        by_event_type: by_event_type
      )
    end

    private

    # `kept`, matching what the list endpoint shows. Deliberately *not*
    # `active`: a cancelled registration is hidden from capacity
    # (Event#full?) but still visible in the organizer's list, and its
    # payment may well have been refunded rather than reversed — so the
    # figures here have to describe the same rows the organizer is looking
    # at, or the count under the table won't match the table.
    def scope
      @scope ||= @event.registrations.kept
    end

    # One grouped query rather than a count per type. Returns a plain
    # id => count hash; types with nobody registered are filled in as zero so
    # the frontend can render every type without checking for missing keys.
    def by_event_type
      counts = RegistrationEventType
        .joins(:registration)
        .where(registrations: { id: scope.select(:id) })
        .group(:event_type_id)
        .count

      @event.event_types.each_with_object({}) do |type, acc|
        acc[type.id] = counts.fetch(type.id, 0)
      end
    end
  end
end
