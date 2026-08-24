# frozen_string_literal: true

module Registrations
  # Resolves the User a guest registration should be attached to — called
  # from Api::V1::RegistrationsController#create when the visitor isn't
  # signed in (see ApplicationController#authenticate_user_optional!).
  #
  # Accepts either an email or a phone number (or both) — phone is Cambodia's
  # most common contact channel, often more reliable than email, so it's a
  # first-class alternative here rather than an email-only flow. At least
  # one of the two must be present; the caller (RegistrationsController)
  # enforces that before calling in, since it needs to render a specific
  # error response either way.
  #
  # When no email is given, a placeholder ("guest-...@guest.rally.invalid",
  # same ".invalid" TLD convention User#discard! already uses for
  # anonymized accounts — reserved by RFC 2606 for exactly this "not a real
  # address" case) is generated so User's `validates :email, presence:
  # true, ...` still gets a normal, valid-looking value with no schema
  # special-casing. User#email_auto_generated flags this so the frontend can
  # later nudge them to add a real one (see UserPayload) and so
  # RegistrationsController skips emailing an address nobody can read.
  #
  # **Attaches to an existing account, without ever issuing a session.**
  # Registration should feel the same whether or not this is someone's
  # first event — a returning participant shouldn't need to remember a
  # password they were never given just to sign up for a second race. So
  # when the typed-in email or phone matches an existing account, this
  # reuses that account for the new registration instead of rejecting the
  # attempt. What it deliberately does NOT do is log that visitor in: no
  # token is generated here, and the controller never returns one for a
  # guest request (see RegistrationsController#create). Proving you know
  # someone's email or phone is enough to register an event on their
  # behalf (the same trust level a store's "guest checkout, order tracked
  # by email" flow uses) — it is not enough to open a full session on their
  # account. Payment for the resulting registration is authorized the same
  # way, via a matching email/phone rather than a login (see
  # Api::V1::PaymentsController).
  #
  # Existing accounts are matched but never *modified* — the guest form's
  # name/phone/email are only used to find (or create) the right account,
  # not to overwrite whatever's already on file for a returning user.
  class GuestCheckout
    # `newly_created` tells the caller whether this call made a brand-new
    # account or attached to one that already existed — RegistrationsController
    # uses it to decide whether the confirmation email's "claim your
    # account, set a password" nudge makes sense (it doesn't for someone
    # who already has a real account, whether or not they know it has a
    # password at all).
    Result = Struct.new(:status, :user, :newly_created, keyword_init: true) do
      def ok?
        status == :ok
      end
    end

    PLACEHOLDER_EMAIL_DOMAIN = "guest.rally.invalid"

    def self.call(email:, phone:, name:)
      new(email: email, phone: phone, name: name).call
    end

    def initialize(email:, phone:, name:)
      @email = email.to_s.downcase.strip.presence
      @phone = phone.to_s.strip.presence
      @name = name.to_s.strip
    end

    def call
      existing = find_existing_account
      return Result.new(status: :ok, user: existing, newly_created: false) if existing

      email_auto_generated = @email.nil?
      user = User.create!(
        email: @email || placeholder_email,
        email_auto_generated: email_auto_generated,
        password: SecureRandom.hex(32)
      )
      user.profile.update!(display_name: @name.presence, phone: @phone)
      Result.new(status: :ok, user: user, newly_created: true)
    end

    private

    # Email wins when both are given and happen to point at two different
    # accounts — the more distinctive identifier, same as how a box office
    # would resolve it by hand rather than erroring out on the mismatch.
    def find_existing_account
      return User.find_by(email: @email) if @email && User.exists?(email: @email)
      return Profile.find_by(phone: @phone)&.user if @phone && Profile.exists?(phone: @phone)

      nil
    end

    def placeholder_email
      "guest-#{SecureRandom.hex(8)}@#{PLACEHOLDER_EMAIL_DOMAIN}"
    end
  end
end
