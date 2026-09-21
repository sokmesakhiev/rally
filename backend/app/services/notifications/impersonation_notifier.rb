# frozen_string_literal: true

module Notifications
  # Tells someone that staff opened their account. See
  # docs/impersonation-design.md D8.
  #
  # Three ways this differs from every other notifier in the app, each
  # deliberate:
  #
  #   * **It does not swallow failures.** Every other notifier wraps its write
  #     in a savepoint and carries on, because losing a bell row is better than
  #     losing a registration or a report. Here the notification *is* the
  #     feature: an impersonation session that exists without having been
  #     announced is precisely the thing this design refuses to allow. The
  #     caller runs this inside the transaction that creates the session, so if
  #     this raises, no session exists to be unannounced.
  #   * **There is no `notify_*` preference**, and that isn't an oversight.
  #     This is not an announcement anyone might reasonably mute, and offering
  #     to mute it would be offering to make impersonation quiet. Same reasoning
  #     as the support reply, one step stronger.
  #   * **Sent at the start, not the end.** "After the fact" in the request
  #     meant "without a consent gate blocking support", not "as late as
  #     possible". Announcing at the start needs no sweep job to catch expired
  #     sessions, can't be skipped by a session that ends in a crash, and gives
  #     the one person who genuinely didn't expect this a chance to say so
  #     while it's still happening.
  module ImpersonationNotifier
    module_function

    KIND = "account_impersonated"

    def started(session)
      Notification.create!(
        user_id: session.user_id,
        kind: KIND,
        title: "A support admin accessed your account",
        # The admin's own words, quoted. That they will be read is what makes
        # writing them a real check rather than a form field.
        body: "Reason given: #{session.reason}",
        url: "/profile"
      )

      # deliver_later, so a mail-server hiccup can't fail the session the way a
      # missing bell row would — the durable half is the Notification row and
      # the admin_actions entry, both already written by the time this is
      # enqueued. Solid Queue retries the mail.
      ImpersonationMailer.account_accessed(session).deliver_later
    end

    # No push notification, on purpose. A push would reach the person's phone
    # seconds after a support admin opened a ticket, which sounds like
    # transparency and reads like an alarm. The bell row and the email say the
    # same thing without the 2am buzz — and `notify_*` preferences, which push
    # respects everywhere else, don't cover this kind, so push would be the one
    # channel here nobody could turn down.
  end
end
