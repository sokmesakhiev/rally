# frozen_string_literal: true

module Registrations
  # Resolves the User a guest registration should be attached to — called
  # from Api::V1::RegistrationsController#create when the visitor isn't
  # signed in (see ApplicationController#authenticate_user_optional!).
  #
  # Deliberately does NOT attach the registration to an *existing* account
  # just because the typed-in email happens to match one — nothing has
  # proven that whoever's at the keyboard actually controls that account,
  # so silently issuing a session for it would be an account-takeover
  # vector. If the email already has an account, this returns a :conflict
  # result instead, and the controller asks them to sign in normally.
  #
  # A brand-new guest gets a real User row with a random, never-shown
  # password — same pattern as User.find_or_create_from_google! uses for
  # Google-only accounts — so has_secure_password's NOT NULL password_digest
  # invariant holds with no schema special-casing. They can claim a real
  # password later via the existing forgot-password flow, using this same
  # email (see RegistrationMailer#confirmation's new_guest_account nudge).
  class GuestCheckout
    Result = Struct.new(:status, :user, keyword_init: true) do
      def ok?
        status == :ok
      end
    end

    def self.call(email:, name:)
      new(email: email, name: name).call
    end

    def initialize(email:, name:)
      @email = email.to_s.downcase.strip
      @name = name.to_s.strip
    end

    def call
      return Result.new(status: :conflict) if User.exists?(email: @email)

      user = User.create!(email: @email, password: SecureRandom.hex(32))
      user.profile.update!(display_name: @name.presence) if @name.present?
      Result.new(status: :ok, user: user)
    end
  end
end
