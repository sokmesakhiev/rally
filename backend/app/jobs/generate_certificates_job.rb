# frozen_string_literal: true

# Runs hourly (see config/recurring.yml) rather than being triggered by any
# one request — certificates are meant to appear automatically once an event
# is over, with no organizer action required. Finds every registration that's
# eligible for a certificate and hasn't gotten one yet, and fans each one out
# to its own RenderCertificateJob rather than doing the (slow — shells out to
# LibreOffice) rendering inline, so one slow/failing certificate can't hold up
# the rest of the sweep.
#
# ── This was dead code until 2026-09-16 ──────────────────────────────────────
# The header used to claim it ran on a schedule; it was absent from
# recurring.yml and nothing called it, so no certificate has ever been
# generated in production. Two consequences worth knowing:
#
#   1. The eligibility scope below had never run against real data, and it
#      was missing every soft-delete guard the rest of the codebase applies.
#      See #eligible_registrations.
#   2. There is a backlog: every event that has already finished with a
#      template attached is eligible the moment this starts running. Hence
#      MAX_PER_RUN.
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

  # Ceiling on how many renders one run may enqueue.
  #
  # The backfill has no date cutoff (product decision: every finished event
  # qualifies, however old), so the first runs face the whole history at once.
  # Each RenderCertificateJob shells out to LibreOffice at ~180 MB peak RSS
  # and 0.25–1.2s, so enqueueing thousands in one go would starve the worker
  # of everything else on its queue — including the registration and payment
  # jobs people are waiting on.
  #
  # Being hourly, a cap doesn't lose anything: whatever is skipped is picked
  # up on the next run, and the backlog drains over hours. In steady state a
  # single event finishing puts its field well under this number, so the cap
  # is never reached and the ordering below never matters.
  MAX_PER_RUN = 200

  def perform
    eligible_registrations.limit(MAX_PER_RUN).pluck(:id).each do |registration_id|
      RenderCertificateJob.perform_later(registration_id)
    end
  end

  private

  # The three soft-delete/moderation guards here are the fix described above,
  # not defensive clutter:
  #
  #   * registrations.deleted_at — #discard! keeps the row for its payment
  #     history but the person is no longer registered (see the partial unique
  #     index on registrations). Certifying a withdrawal is wrong, and it's
  #     also unrecoverable: the PDF is in S3 and the participant can see it.
  #   * events.deleted_at — a soft-deleted event is gone from every other
  #     read path; generating new artefacts for it would be the only thing in
  #     the codebase that still treats it as live.
  #   * events.suspended_at — a suspension is an admin freezing the event out
  #     of the owner's hands. Minting certificates in that state contradicts
  #     the point of the freeze, and unlike the other two it can be reversed,
  #     so nothing is lost by waiting: unsuspending makes these eligible again
  #     on the next hourly run.
  #
  # `.limit` is applied by the caller. The ordering is oldest-event-first so a
  # capped run drains the backlog in a predictable order rather than
  # re-rendering whatever the planner happened to return.
  def eligible_registrations
    Registration
      .kept
      .joins(:event)
      .where(status: "confirmed", payment_status: "paid")
      .where(events: { deleted_at: nil, suspended_at: nil })
      .where.not(events: { certificate_template_url: nil })
      .where("COALESCE(events.end_at, events.start_at) <= ?", Time.current)
      .left_joins(:certificate)
      .where(certificates: { id: nil })
      .order(Arel.sql("COALESCE(events.end_at, events.start_at) ASC"))
  end
end
