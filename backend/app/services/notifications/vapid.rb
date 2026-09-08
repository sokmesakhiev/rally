# frozen_string_literal: true

module Notifications
  # VAPID ("Voluntary Application Server Identification") is how a push service
  # knows a notification really came from us. It's one keypair for the whole
  # application, not per user.
  #
  # Read from ENV rather than config/payway.yml's config_for pattern because
  # there is nothing per-environment to express beyond the keys themselves —
  # production gets them from ECS (infrastructure/secrets.tf), development from
  # .env, and neither has any other setting to vary.
  #
  # Generate a pair with:
  #
  #   bundle exec ruby -rwebpush -e 'puts WebPush.generate_key.to_h'
  #
  # The public key is genuinely public — it's handed to every browser that
  # subscribes. The private key is a secret and must never reach the frontend.
  #
  # **Rotating the keypair invalidates every existing subscription.** Browsers
  # tie a subscription to the public key it was created with, so every device
  # silently stops receiving notifications and has to re-subscribe. Treat these
  # as long-lived.
  module Vapid
    module_function

    def public_key
      ENV["VAPID_PUBLIC_KEY"].presence
    end

    def private_key
      ENV["VAPID_PRIVATE_KEY"].presence
    end

    # The `sub` claim: a contact address the push service can use if our
    # notifications start misbehaving. The spec requires mailto: or https:,
    # and push services reject a malformed one.
    # Quotes and angle brackets are excluded, not just whitespace: the most
    # likely way this goes wrong is a value arriving already quoted (dotenv
    # strips surrounding quotes locally, ECS does not), which would produce
    # mailto:"a@b.c" — well-formed to a lax pattern, rejected by every push
    # service.
    VALID_SUBJECT = %r{\A(mailto:[^\s"'<>]+@[^\s"'<>]+|https://[^\s"'<>]+)\z}

    def subject
      ENV["VAPID_SUBJECT"].presence || "mailto:#{ENV.fetch('MAILER_FROM_EMAIL', 'noreply@rails-dev.com')}"
    end

    def subject_valid?
      subject.match?(VALID_SUBJECT)
    end

    # Push is off unless the keypair is complete AND the subject is one a push
    # service will accept.
    #
    # Folding the subject check in here rather than raising from #subject is
    # deliberate: an invalid `sub` fails at send time, once per notification,
    # inside a background job — the least visible place it could possibly go
    # wrong. Treating it as "not configured" instead means the API reports
    # enabled: false, the frontend never offers the feature, and the reason is
    # logged once. Same "unset means cleanly off" convention as the rest of the
    # app, extended to "misconfigured means cleanly off".
    def configured?
      return false unless public_key.present? && private_key.present?
      return true if subject_valid?

      Rails.logger.warn(
        "[push] VAPID keypair is set but the subject #{subject.inspect} is not a " \
        "mailto: or https: URL — push is disabled. Set VAPID_SUBJECT."
      )
      false
    end
  end
end
