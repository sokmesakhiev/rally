# frozen_string_literal: true

# Sweeps events whose registration has closed and still have people waiting,
# and ends those waitlists (Waitlists::CancelForClosedEvent).
#
# This exists for the **deadline** path specifically. When an organizer presses
# Close, the controller runs the service inline and the queue clears while they
# are looking at it. But `registration_closes_at` is a deadline that is
# evaluated rather than stored (Event#registration_closed?) — no code runs when
# it passes, by design, because the alternative was a cron job flipping a
# boolean on every event on the platform. That design is right for *reading*
# closed-ness and leaves exactly one thing undone: the queue nobody told.
#
# It also backstops the manual path, which is why the inline call isn't enough
# on its own — a deploy, a crash or a rolled-back transaction between the close
# and the cancellation would otherwise leave that queue waiting indefinitely,
# which is the original bug.
#
# Cheap in the normal case: the scope below matches only events that are both
# closed and still have a `waiting` entry, which after the first pass is
# almost always none.
class CancelWaitlistsForClosedEventsJob < ApplicationJob
  queue_as :default

  def perform
    events_with_stranded_waitlists.find_each do |event|
      result = Waitlists::CancelForClosedEvent.call(event)
      next if result.cancelled.zero?

      Rails.logger.info(
        { event: "waitlist.closed_sweep", event_id: event.id, cancelled: result.cancelled }.to_json
      )
    end
  end

  private

  # "Closed" has to be expressed in SQL here rather than by calling
  # Event#registration_closed? per row — the predicate is the same two
  # conditions ORed (a manual close, or a deadline now in the past), and
  # keeping them in step matters more than the small duplication. A spec
  # asserts this scope agrees with the model predicate.
  def events_with_stranded_waitlists
    Event.kept
         .where(
           "events.registration_closed_at IS NOT NULL OR " \
           "(events.registration_closes_at IS NOT NULL AND events.registration_closes_at <= :now)",
           now: Time.current
         )
         .where(id: WaitlistEntry.kept.waiting.select(:event_id))
  end
end
