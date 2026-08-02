# frozen_string_literal: true

# Runs on a schedule (see config/recurring.yml) rather than being triggered
# by any one request — certificates are meant to appear automatically once
# an event is over, with no organizer action required. Finds every
# registration that's eligible for a certificate and hasn't gotten one yet,
# and fans each one out to its own RenderCertificateJob rather than doing the
# (slow — shells out to LibreOffice) rendering inline, so one slow/failing
# certificate can't hold up the rest of the sweep.
#
# "Eligible" mirrors what a normal registration create already guarantees
# for a settled spot: status: "confirmed" and payment_status: "paid" (which
# a free registration reaches immediately at creation — see
# RegistrationsController#create — so this isn't a paid-events-only check).
# There's deliberately no attendance/check-in requirement yet — see the
# "check-in / attendance tracking" backlog item — so today this certifies
# everyone who registered and paid for an event that's over, not just people
# who actually showed up.
class GenerateCertificatesJob < ApplicationJob
  queue_as :default

  def perform
    eligible_registrations.find_each do |registration|
      RenderCertificateJob.perform_later(registration.id)
    end
  end

  private

  def eligible_registrations
    Registration
      .joins(:event)
      .where(status: "confirmed", payment_status: "paid")
      .where.not(events: { certificate_template_url: nil })
      .where("COALESCE(events.end_at, events.start_at) <= ?", Time.current)
      .left_joins(:certificate)
      .where(certificates: { id: nil })
  end
end
