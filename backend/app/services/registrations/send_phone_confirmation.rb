# frozen_string_literal: true

module Registrations
  # The phone-only-guest equivalent of RegistrationMailer#confirmation.
  # Called (via SendPhoneConfirmationJob) from
  # Api::V1::RegistrationsController#create exactly where the mailer branch
  # is skipped today, i.e. registrant.email_auto_generated? — see
  # Registrations::GuestCheckout.
  #
  # Goes through Sms::Client, which is a stub (Sms::Adapters::NullAdapter)
  # until Ticket 1's provider decision is made — see
  # registration-engagement-tickets.md at the repo root. No real message is
  # sent yet, but the trigger point, message content, and calling shape are
  # all in place, so wiring up a real provider later is a one-file change (a
  # new Sms::Client adapter), not a new feature.
  class SendPhoneConfirmation
    def self.call(registration)
      new(registration).call
    end

    def initialize(registration)
      @registration = registration
      @event = registration.event
      @user = registration.user
    end

    def call
      phone = @user.profile&.phone
      return unless phone.present?

      Sms::Client.deliver(to: phone, body: message)
    end

    private

    def message
      "Rally: you're registered for #{@event.title} on #{@event.start_at.strftime('%b %d')}. " \
        "Ticket: #{event_url}"
    end

    # Same ENV.fetch('FRONTEND_URL', ...) pattern ApplicationMailer#frontend_url
    # uses — duplicated rather than shared since this is the only non-mailer
    # caller so far; worth extracting to a shared helper if a second one shows up.
    def event_url
      "#{ENV.fetch('FRONTEND_URL', 'http://localhost:5173').chomp('/')}/events/#{@event.id}"
    end
  end
end
