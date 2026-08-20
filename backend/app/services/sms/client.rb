# frozen_string_literal: true

module Sms
  # Thin dispatcher in front of whichever SMS/messaging provider ends up
  # getting picked for Ticket 1 (see registration-engagement-tickets.md at
  # the repo root) — no real provider is wired up yet, and nothing is
  # actually sent today. `.deliver` looks up an adapter by SMS_PROVIDER and
  # forwards to it; the only adapter that exists right now is
  # Sms::Adapters::NullAdapter, which just logs what would have been sent
  # and reports success, so callers (Registrations::SendPhoneConfirmation)
  # can be built, wired into the registration flow, and tested against a
  # real interface before a provider is chosen.
  #
  # To wire up a real provider later: add a new Sms::Adapters::<Provider>
  # class implementing #deliver(to:, body:) -> Sms::Client::Result, register
  # it in ADAPTERS below, and set SMS_PROVIDER in the environment. No caller
  # code needs to change.
  class Client
    Result = Struct.new(:success, :provider, :error, keyword_init: true) do
      def success?
        success
      end
    end

    ADAPTERS = {
      "null" => -> { Sms::Adapters::NullAdapter.new }
    }.freeze

    def self.deliver(to:, body:)
      adapter_for(ENV["SMS_PROVIDER"]).deliver(to: to, body: body)
    end

    def self.adapter_for(name)
      key = name.presence || "null"
      factory = ADAPTERS[key]

      unless factory
        raise ArgumentError,
          "Unknown SMS_PROVIDER #{key.inspect} — add an adapter to Sms::Client::ADAPTERS"
      end

      factory.call
    end
  end
end
