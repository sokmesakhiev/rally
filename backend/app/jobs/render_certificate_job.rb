# frozen_string_literal: true

# Renders one registration's certificate — see Certificates::RenderPdf for
# the actual work. Split out from GenerateCertificatesJob so a conversion
# failure (bad template, soffice hiccup) only affects this one registration;
# it'll simply be picked up again on the next sweep, since a registration
# without a Certificate row is exactly what GenerateCertificatesJob looks for.
class RenderCertificateJob < ApplicationJob
  queue_as :default

  def perform(registration_id)
    registration = Registration.find_by(id: registration_id)
    return unless registration

    Certificates::RenderPdf.call(registration)
  rescue Certificates::RenderPdf::ConversionError => e
    Rails.logger.error(
      "[certificates] failed to render for registration=#{registration_id}: #{e.message}"
    )
  end
end
