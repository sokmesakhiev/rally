# frozen_string_literal: true

module Sms
  module Adapters
    # Default adapter — stands in until a real SMS/messaging provider is
    # chosen for Ticket 1 (see registration-engagement-tickets.md at the repo
    # root). Logs what *would* have been sent instead of sending it, and
    # reports success, so the rest of the registration flow
    # (Registrations::SendPhoneConfirmation and its callers/specs) can be
    # exercised end-to-end today. Swap SMS_PROVIDER to a real adapter's key
    # once one exists — see Sms::Client::ADAPTERS.
    class NullAdapter
      def deliver(to:, body:)
        Rails.logger.info("[sms:null] would send to #{to}: #{body}")
        Sms::Client::Result.new(success: true, provider: "null", error: nil)
      end
    end
  end
end
