# frozen_string_literal: true

module Notifications
  # Tells a participant that support replied.
  #
  # A deliberate sibling of RegistrationNotifier rather than a method on it:
  # every one of that module's entry points takes a `registration` and reads
  # `registration.event.title`, and a support thread has neither. Same shape,
  # different subject — sharing the file would mean threading a nil registration
  # through code written to assume one.
  #
  # ## Who gets notified, and when
  #
  # Only a **staff** message notifies, and only the participant. The participant
  # writing needs no notification (they just typed it), and staff have the
  # console's own badge. `system` messages — currently just the resolve notice —
  # don't notify either: the thread's new state is visible the moment they next
  # look, and a push saying "your conversation was closed" is noise rather than
  # news.
  #
  # ## Channels, and how they differ
  #
  #   * **in-app row** — always written, exactly as with registrations. The bell
  #     is something you go and look at.
  #   * **push** — sent unconditionally too, unlike most kinds. There is no
  #     `notify_support_reply` column and deliberately so: a support reply is a
  #     direct answer to something this person started, which puts it with the
  #     registration confirmation (transactional) rather than with the payment
  #     and waitlist notices (announcements you might reasonably mute). Muting
  #     the answer to your own question would be a strange thing to offer.
  #   * **email** — only if they still haven't read it after a delay. See
  #     SupportReplyFallbackEmailJob.
  module SupportNotifier
    module_function

    def staff_replied(message)
      return unless message.from_staff?

      conversation = message.conversation
      participant = conversation.user
      return if participant.nil?

      record(conversation, participant, message)

      SendPushNotificationJob.perform_later(
        participant.id,
        title: "Rally Support replied",
        body: preview(message.body),
        url: "/",
        # Collapses on the participant's device: three replies in a row while
        # they're away should be one notification, not three.
        tag: "support-#{conversation.id}"
      )

      SupportReplyFallbackEmailJob.set(wait: SupportReplyFallbackEmailJob::DELAY)
                                  .perform_later(message.id)
    end

    # Same swallow-and-report contract as RegistrationNotifier#record, and for
    # the same reason: a support reply that saved and then 500'd because a bell
    # row couldn't be written would be a far worse bug than a missing badge.
    #
    # The savepoint matters here too — PostMessage calls this from inside
    # `conversation.with_lock`, so a bare rescue would leave that transaction
    # aborted and the reply itself would fail to commit.
    def record(conversation, participant, message)
      Notification.transaction(requires_new: true) do
        Notification.create!(
          user_id: participant.id,
          kind: "support_reply",
          title: "Rally Support replied",
          body: preview(message.body),
          url: "/"
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[support chat] could not record support_reply: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry) && Sentry.initialized?
      nil
    end

    # Notification#body is a string column and a push payload has a practical
    # size limit, so the preview is truncated rather than carrying a whole
    # reply. The full text is one tap away.
    def preview(body)
      body.to_s.truncate(140)
    end
  end
end
