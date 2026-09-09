# frozen_string_literal: true

module Notifications
  # Push counterparts to the RegistrationMailer messages.
  #
  # Exists so the payload wording lives in one place rather than being copied
  # to each trigger site — `payment_received` alone fires from two paths (the
  # polling endpoint and the ABA webhook), and prose duplicated across call
  # sites drifts.
  #
  # Every method here is additive: it sits *next to* the existing
  # `.deliver_later`, never replacing it. Email reaches everyone; push reaches
  # the subset who opted in on a device. A participant must never depend on
  # push to learn something.
  #
  # Preference handling deliberately mirrors the mailers exactly, so a person
  # can't end up silenced on one channel and not the other:
  #
  #   * #confirmation is unconditional, because the confirmation email is.
  #     There is no notify_confirmation column and adding one would change
  #     existing email behaviour, which is transactional by design.
  #   * the other two check the same wants_notification? flag their mailer
  #     already checks — the caller does that check, since it's already
  #     wrapped around the mailer call.
  #
  # Copy is English only. Mailers aren't localized either, and there's no
  # stored user locale to translate against — worth revisiting together, not
  # separately.
  module RegistrationPush
    module_function

    def confirmation(registration)
      enqueue(
        registration,
        title: "You're registered",
        body: "You're in for #{registration.event.title}.",
        tag: "registration-#{registration.id}"
      )
    end

    def payment_received(registration)
      enqueue(
        registration,
        title: "Payment received",
        body: "Your payment for #{registration.event.title} is confirmed.",
        tag: "payment-#{registration.id}"
      )
    end

    def promoted_from_waitlist(registration)
      enqueue(
        registration,
        title: "A spot opened up",
        body: "You're off the waitlist for #{registration.event.title}.",
        tag: "waitlist-#{registration.id}"
      )
    end

    # Deep-links to the participant's own dashboard rather than the public
    # event page — every one of these notifications is about *their*
    # registration, and that's where its current state lives.
    def enqueue(registration, title:, body:, tag:)
      user_id = registration.user_id
      return if user_id.nil?

      SendPushNotificationJob.perform_later(
        user_id, title: title, body: body, url: "/dashboard", tag: tag
      )
    end
  end
end
