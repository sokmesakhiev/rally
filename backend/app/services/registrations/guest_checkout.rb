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
  # special-casing. User#email_auto_generated flags
  # this so the frontend can later nudge them to add a real one (see
  # UserPayload) and so RegistrationsController skips emailing an address
  # nobody can read.
  #
  # Deliberately does NOT attach the registration to an *existing* account
  # just because the typed-in email or phone happens to match one —
  # nothing has proven that whoever's at the keyboard actually controls
  # that account, so silently issuing a session for it would be an
  # account-takeover vector. If either identifier already has an account,
  # this returns a :conflict result (naming which field conflicted) instead,
  # and the controller asks them to sign in normally.
  class GuestCheckout
    Result = Struct.new(:status, :user, :conflict_field, keyword_init: true) do
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
      return Result.new(status: :conflict, conflict_field: :email) if @email && User.exists?(email: @email)
      return Result.new(status: :conflict, conflict_field: :phone) if @phone && Profile.exists?(phone: @phone)

      email_auto_generated = @email.nil?
      user = User.create!(
        email: @email || placeholder_email,
        email_auto_generated: email_auto_generated,
        password: SecureRandom.hex(32)
      )
      user.profile.update!(display_name: @name.presence, phone: @phone)
      Result.new(status: :ok, user: user)
    end

    private

    def placeholder_email
      "guest-#{SecureRandom.hex(8)}@#{PLACEHOLDER_EMAIL_DOMAIN}"
    end
  end
end
