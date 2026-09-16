# frozen_string_literal: true

module Waitlists
  # Ends the waitlist for an event that has stopped taking sign-ups: every
  # entry still "waiting" is cancelled, and its owner is told once that they
  # won't be promoted.
  #
  # ── Why this has to exist ───────────────────────────────────────────────────
  # Registration validates `registration_is_open` on create, and promotion
  # creates a Registration. So on a closed event every promotion raises
  # RecordInvalid, which Waitlists::PromoteNext used to swallow as though it
  # were a lost capacity race — leaving each entry "waiting" indefinitely with
  # nothing logged, nothing shown to the organizer, and nothing said to the
  # person. WaitlistEntry's own comment asserted the opposite ("an entry that
  # already exists can still be promoted"); it was wrong.
  #
  # The product decision is that closing is final: an organizer closes to fix a
  # headcount — printing bibs, confirming catering, closing a permit — and a
  # promotion afterwards adds someone they have already counted. So a spot
  # freed on a closed event stays empty, and the queue is told rather than left
  # hoping.
  #
  # ── Two ways an event closes, one of which has no moment ────────────────────
  # `registration_closed_at` is a discrete act with an obvious hook. But
  # `registration_closes_at` is a **deadline that is evaluated, never stored**
  # (deliberately — see Event#registration_closed?), so nothing runs when it
  # passes. Hooking only the manual path would leave every deadline-closed
  # event stranding its waitlist exactly as before, which is the bug rather
  # than a smaller version of it.
  #
  # Hence one service with two triggers: called inline when an organizer
  # presses Close (so they watch the waitlist clear), and swept hourly by
  # CancelWaitlistsForClosedEventsJob, which catches the deadline path and
  # anything the inline call missed to a crash or a deploy. Same shape as
  # `payment_received` firing from both the polling endpoint and the ABA
  # webhook — one place for the behaviour, several places that trigger it.
  #
  # Idempotent by construction: it only ever touches rows that are still
  # `waiting`, so the sweep finding nothing is the normal case and a second run
  # notifies nobody twice.
  class CancelForClosedEvent
    Result = Struct.new(:cancelled, keyword_init: true)

    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      return Result.new(cancelled: 0) if @event.accepting_signups?

      cancelled = 0

      entries.find_each do |entry|
        cancelled += 1 if cancel(entry)
      end

      Result.new(cancelled: cancelled)
    end

    private

    # `kept` as well as `waiting`: Event#discard! cascades to its waitlist
    # entries (setting both deleted_at and status "cancelled"), and a discarded
    # event's queue should hear nothing at all — the event is gone, not closed.
    def entries
      @event.waitlist_entries.kept.waiting.includes(:user, :event)
    end

    # Per-entry rather than one `update_all`, because each person gets their own
    # notification and a single failure must not take the rest of the queue
    # down with it. An `update_all` would also skip the model, and `status` is
    # validated there.
    #
    # The notification is sent *inside* the transaction on purpose: the
    # notifier's own record writes in a savepoint and swallows its failures
    # (see WaitlistNotifier#record), so it cannot abort this, while a rollback
    # here still prevents announcing a cancellation that didn't happen.
    def cancel(entry)
      WaitlistEntry.transaction do
        entry.update!(status: "cancelled")
        Notifications::WaitlistNotifier.registration_closed(entry)
      end

      true
    rescue StandardError => e
      # One bad row must not strand the rest of the queue — the whole failure
      # this service exists to fix is people left waiting silently, and an
      # exception halfway through the list would recreate it for everyone
      # after that point. The hourly sweep retries whatever is left.
      Rails.logger.warn(
        "[waitlist] could not cancel entry #{entry.id} on closed event " \
        "#{@event.id}: #{e.class}: #{e.message}"
      )
      Sentry.capture_exception(e) if defined?(Sentry) && Sentry.initialized?
      false
    end
  end
end
