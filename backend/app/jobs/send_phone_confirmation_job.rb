# frozen_string_literal: true

# Background wrapper around Registrations::SendPhoneConfirmation, mirroring
# how RegistrationMailer.confirmation is sent via #deliver_later rather than
# inline — kept out of the request/transaction because, once a real
# Sms::Client adapter exists, delivering will mean an outbound HTTP call, and
# that shouldn't happen inside RegistrationsController#create's
# Registration.transaction block or block the response.
class SendPhoneConfirmationJob < ApplicationJob
  queue_as :default

  def perform(registration)
    Registrations::SendPhoneConfirmation.call(registration)
  end
end
