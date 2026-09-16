# frozen_string_literal: true

module Notifications
  # Notifications about a WaitlistEntry rather than a Registration.
  #
  # A sibling of RegistrationNotifier rather than a method on it, for the same
  # reason SupportNotifier is: every entry point there takes a `registration`
  # and reads `registration.event.title` / `registration.user_id`. A waitlist
  # entry has an event and a user but no registration, and threading a nil
  # registration through code written to assume one is how that file stops
  # being readable.
  #
  # The preference split matches RegistrationNotifier's exactly, because it's
  # the codebase's rule rather than this module's choice: **the push respects
  # `notify_*`** (it interrupts), **the in-app row is always written** (the bell
  # is something you go and look at). Someone who muted waitlist pushes still
  # needs a way to discover that the event they were queueing for closed.
  #
  # Copy is English only, matching the mailers and RegistrationNotifier — there
  # is no stored user locale to translate against, and doing that properly is
  # one job across all of them, not a thing to start here.
  module WaitlistNotifier
    module_function

    # The organizer closed registration (or an announced deadline passed), so
    # this entry will never be promoted. Deliberately phrased as a final
    # outcome, not a status update: the whole point is that the person stops
    # waiting for something that isn't coming.
    def registration_closed(entry)
      deliver(
        entry,
        kind: "waitlist_closed",
        # Same preference as a promotion — it's the same waitlist channel, and
        # this is the message that channel exists to end with. Someone who
        # muted it still gets the bell row.
        preference: :promoted_from_waitlist,
        title: "Waitlist closed",
        body: "Registration for #{entry.event.title} has closed, so you won't be promoted from the waitlist."
      )
    end

    # ── internals ─────────────────────────────────────────────────────────────

    def deliver(entry, kind:, preference:, title:, body:)
      user = entry.user
      return if user.nil?

      record(entry, kind: kind, title: title, body: body)

      return unless push_wanted?(user, preference)

      SendPushNotificationJob.perform_later(
        user.id, title: title, body: body, url: "/dashboard", tag: "waitlist-#{entry.id}"
      )
    end

    # Mirrors Registration#wants_notification? rather than reimplementing it,
    # including the `!= false` — a user with no profile row, or a column that
    # is nil, means "not opted out", so the push goes. Written as truthiness
    # instead, a missing profile would silently mean "never push", which is the
    # opposite default and the kind of divergence nobody notices until someone
    # asks why they stopped getting notifications.
    def push_wanted?(user, preference)
      return true if preference.nil?

      user.profile&.public_send(:"notify_#{preference}?") != false
    end

    # Same savepoint-and-swallow shape as RegistrationNotifier#record, and for
    # the same reason: this runs inside Waitlists::CancelForClosedEvent's
    # transaction, so a bare rescue would leave the enclosing transaction
    # aborted and every statement after it failing with
    # PG::InFailedSqlTransaction. A missing bell row must not be able to fail
    # the close.
    def record(entry, kind:, title:, body:)
      Notification.transaction(requires_new: true) do
        Notification.create!(
          user_id: entry.user_id,
          event_id: entry.event_id,
          kind: kind,
          title: title,
          body: body,
          url: "/dashboard"
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[notifications] could not record #{kind}: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry) && Sentry.initialized?
      nil
    end
  end
end
