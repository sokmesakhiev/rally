# frozen_string_literal: true

module Results
  # Builds the public results/leaderboard payload for one event — see
  # Api::V1::ResultsController#index. Grouped by event type (mirroring the
  # "Per-type breakdown" already shown to organizers on the manage-event
  # page) when the event has any; a single combined group otherwise. Within
  # each group, ranked by finish_time_seconds ascending using standard
  # competition ranking — ties share a place, and the next distinct time's
  # place accounts for how many were tied ahead of it (1, 2, 2, 4 — not
  # 1, 2, 2, 3) — the norm for race results, not just array position.
  #
  # Only registrations with a recorded finish_time_seconds are included.
  # Every non-race "gathering" event simply never gets one (see Result's
  # class comment), so its groups all come back empty — that emptiness is
  # exactly what the frontend uses to decide whether a "Results" section
  # appears on the public event page at all, rather than gating on category.
  class BuildLeaderboard
    def self.call(event:)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      types = event.event_types.to_a
      return [ group(nil, timed_registrations) ] if types.empty?

      types.map { |type| group(type, timed_registrations.select { |r| r.event_types.include?(type) }) }
    end

    private

    attr_reader :event

    # .active excludes cancelled AND discarded registrations (see
    # Registration#discard!, which sets status: "cancelled" too) — a
    # refunded or organizer-removed participant shouldn't appear on public
    # results even if a stray finish time was recorded before that happened.
    def timed_registrations
      @timed_registrations ||= event.registrations.active
        .joins(:result)
        .where.not(results: { finish_time_seconds: nil })
        .includes(:result, event_types: [], user: :profile)
        .to_a
    end

    def group(event_type, registrations)
      {
        event_type_id: event_type&.id,
        event_type_name: event_type&.name,
        results: rank(registrations.sort_by { |r| r.result.finish_time_seconds })
      }
    end

    def rank(sorted_registrations)
      placement = 0
      previous_time = nil
      sorted_registrations.each_with_index.map do |registration, index|
        time = registration.result.finish_time_seconds
        placement = index + 1 if time != previous_time
        previous_time = time
        {
          placement: placement,
          registration_id: registration.id,
          user_id: registration.user_id,
          display_name: registration.user.profile&.display_name,
          finish_time_seconds: time
        }
      end
    end
  end
end
