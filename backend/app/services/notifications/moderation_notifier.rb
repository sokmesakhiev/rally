# frozen_string_literal: true

module Notifications
  # The first staff-facing notifier in the app. Every other one
  # (RegistrationNotifier, SupportNotifier, WaitlistNotifier) writes to one
  # participant about their own registration; this writes to *every admin*
  # about somebody else's event, which is a different shape and why it isn't
  # a method on any of them.
  #
  # Three things follow from the audience being a pool rather than a person:
  #
  #   * **No push.** Push subscriptions are per-device and the `notify_*`
  #     preferences are a participant's, not a moderator's. A staff alert that
  #     an organizer could mute by toggling their own notification settings
  #     would be worse than none. In-app bell rows only.
  #   * **One row per admin, deduplicated per event.** An event with twelve
  #     reports should put one item in each admin's bell, not twelve — the
  #     count belongs in the queue, where it sets priority. Without this the
  #     bell becomes the thing you learn to ignore on the one day it matters.
  #   * **It never fails the report.** Same savepoint-and-swallow as
  #     RegistrationNotifier#record: a reporter's submission must be saved even
  #     if no bell row can be written, because losing the report is the one
  #     outcome this whole feature exists to prevent.
  module ModerationNotifier
    module_function

    KIND = "event_reported"

    def event_reported(event)
      return if event.nil?

      title = "Event reported"
      body = "#{event.title} has been reported and needs review."

      admins.find_each do |admin|
        next if already_notified?(admin, event)

        record(admin: admin, event: event, title: title, body: body)
      end
    end

    # `kept` and not suspended: a discarded or suspended staff account
    # shouldn't collect a moderation queue it can't act on.
    def admins
      User.where(admin: true, deleted_at: nil, suspended_at: nil)
    end

    # Unread only. A report landing on an event an admin already dealt with
    # and dismissed from their bell is genuinely new information; a second
    # report on something still sitting unread is not.
    def already_notified?(admin, event)
      Notification.where(user_id: admin.id, event_id: event.id, kind: KIND, read_at: nil).exists?
    end

    def record(admin:, event:, title:, body:)
      Notification.transaction(requires_new: true) do
        Notification.create!(
          user_id: admin.id,
          event_id: event.id,
          kind: KIND,
          title: title,
          body: body,
          # Deep-links into the admin console's moderation tab rather than the
          # public event page — the admin's next action is triage, not reading
          # the listing. See KNOWN_NOTIFICATION_PATHS in notification-bell.tsx:
          # a path that list doesn't know about is ignored rather than
          # navigated to, so adding one here means adding it there too.
          url: "/admin?tab=reports"
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[notifications] could not record #{KIND}: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry) && Sentry.initialized?
      nil
    end
  end
end
