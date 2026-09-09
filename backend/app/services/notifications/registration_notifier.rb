# frozen_string_literal: true

module Notifications
  # The non-email channels for the RegistrationMailer messages: an in-app
  # Notification row (what the header bell counts) and a web push to any
  # subscribed device.
  #
  # Both are written from here so a given event's wording exists in exactly one
  # place. `payment_received` alone fires from two paths — the polling endpoint
  # and the ABA webhook — and prose duplicated across call sites drifts.
  #
  # Everything here is additive: it sits *next to* the existing
  # `.deliver_later`, never replacing it. Email reaches everyone; these reach
  # people who are looking at the app or opted into push. A participant must
  # never depend on either to learn something.
  #
  # ## On preferences
  #
  # These methods are called *outside* the caller's `wants_notification?`
  # guard — unlike the mailer — because the two channels here want different
  # answers, and the decision belongs in one place rather than being split
  # between here and four call sites:
  #
  #   * the **push** respects `notify_*`, exactly as the mailer does. It's an
  #     interruption, and that flag means "don't interrupt me".
  #   * the **in-app row is always written**. The bell is something you go and
  #     look at, not something that arrives. Suppressing it would leave someone
  #     who muted payment emails with no way at all to discover their payment
  #     cleared — worse than a bell they can ignore.
  #
  # Copy is English only. The mailers aren't localized either, and there's no
  # stored user locale to translate against — worth doing together, not
  # separately.
  module RegistrationNotifier
    module_function

    def confirmation(registration)
      deliver(
        registration,
        kind: "registration_confirmed",
        # No notify_confirmation column exists — the confirmation email is
        # unconditional too, being transactional. See the push ticket.
        preference: nil,
        title: "You're registered",
        body: "You're in for #{registration.event.title}.",
        tag: "registration-#{registration.id}"
      )
    end

    def payment_received(registration)
      deliver(
        registration,
        kind: "payment_received",
        preference: :payment_received,
        title: "Payment received",
        body: "Your payment for #{registration.event.title} is confirmed.",
        tag: "payment-#{registration.id}"
      )
    end

    def promoted_from_waitlist(registration)
      deliver(
        registration,
        kind: "promoted_from_waitlist",
        preference: :promoted_from_waitlist,
        title: "A spot opened up",
        body: "You're off the waitlist for #{registration.event.title}.",
        tag: "waitlist-#{registration.id}"
      )
    end

    def refund_issued(registration)
      deliver(
        registration,
        kind: "refund_issued",
        preference: :refund_issued,
        title: "Refund issued",
        body: "Your refund for #{registration.event.title} is on its way.",
        tag: "refund-#{registration.id}"
      )
    end

    def event_details_changed(registration)
      deliver(
        registration,
        kind: "event_details_changed",
        preference: :event_details_changed,
        title: "Event details changed",
        body: "#{registration.event.title} has been updated.",
        tag: "event-#{registration.event_id}"
      )
    end

    # Deep-links to the participant's own dashboard rather than the public
    # event page — every one of these is about *their* registration, and that's
    # where its current state lives.
    def deliver(registration, kind:, preference:, title:, body:, tag:)
      user_id = registration.user_id
      return if user_id.nil?

      record(registration, kind: kind, title: title, body: body)

      return unless push_wanted?(registration, preference)

      SendPushNotificationJob.perform_later(
        user_id, title: title, body: body, url: "/dashboard", tag: tag
      )
    end

    # nil preference means "always" — see #confirmation.
    def push_wanted?(registration, preference)
      preference.nil? || registration.wants_notification?(preference)
    end

    # A failed notification must never fail the thing that triggered it. A
    # payment that succeeded and then 500s because a bell row couldn't be
    # written would be a far worse bug than a missing badge.
    #
    # The create runs inside its own savepoint (`requires_new: true`), not
    # just a bare rescue: some callers (Refunds::IssueRefund, and
    # mark_paid_from_payment! paths) invoke this from inside their own
    # transaction. Once Postgres raises, the *enclosing* transaction is
    # aborted too — every statement after a plain rescue would fail with
    # PG::InFailedSqlTransaction, turning a missing bell row into the very
    # 500-after-a-successful-payment this rescue exists to prevent. A
    # savepoint scopes the rollback to just this insert.
    def record(registration, kind:, title:, body:)
      Notification.transaction(requires_new: true) do
        Notification.create!(
          user_id: registration.user_id,
          event_id: registration.event_id,
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
