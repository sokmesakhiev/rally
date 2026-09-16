require "rails_helper"

RSpec.describe GenerateCertificatesJob, type: :job do
  # rails_helper only wires ActiveJob::TestHelper in for `type: :request`
  # specs — see spec/services/waitlists/promote_next_spec.rb for the same
  # fix applied there. `have_enqueued_job` needs it included directly here.
  include ActiveJob::TestHelper

  let(:organizer) { create(:user) }

  def past_event(**attrs)
    create(:event, :past, creator: organizer, certificate_template_url: "https://example.com/t.odt", **attrs)
  end

  it "enqueues RenderCertificateJob for confirmed, paid registrations on ended events with a template" do
    event = past_event
    registration = create(:registration, event: event, status: "confirmed", payment_status: "paid")

    expect { described_class.perform_now }
      .to have_enqueued_job(RenderCertificateJob).with(registration.id)
  end

  it "skips events with no certificate template" do
    event = create(:event, :past, creator: organizer, certificate_template_url: nil)
    create(:registration, event: event, status: "confirmed", payment_status: "paid")

    expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
  end

  it "skips events that haven't ended yet" do
    event = create(:event, creator: organizer, certificate_template_url: "https://example.com/t.odt",
                            start_at: 1.week.from_now, end_at: 2.weeks.from_now)
    create(:registration, event: event, status: "confirmed", payment_status: "paid")

    expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
  end

  it "skips registrations that already have a certificate" do
    event = past_event
    registration = create(:registration, event: event, status: "confirmed", payment_status: "paid")
    create(:certificate, :with_file, registration: registration)

    expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
  end

  it "skips unpaid registrations" do
    event = past_event
    create(:registration, event: event, status: "confirmed", payment_status: "unpaid")

    expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
  end

  it "skips cancelled registrations" do
    event = past_event
    create(:registration, event: event, status: "cancelled", payment_status: "paid")

    expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
  end

  # ── Soft-delete and moderation guards ───────────────────────────────────────
  # These three were missing from the eligibility scope until 2026-09-16 and
  # nothing caught it, because the job was absent from recurring.yml and called
  # from nowhere — it had never run against real data at all. The examples above
  # passed the whole time; they only covered the filters that were present.
  describe "records that are hidden everywhere else" do
    # Unrecoverable if it ever fires: the PDF lands in S3 and the participant
    # can see it in their own dashboard. #discard! keeps the row for its payment
    # history, but the person is no longer registered.
    it "skips discarded registrations" do
      event = past_event
      create(:registration, event: event, status: "confirmed", payment_status: "paid").discard!

      expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
    end

    it "skips registrations on a soft-deleted event" do
      event = past_event
      create(:registration, event: event, status: "confirmed", payment_status: "paid")
      event.update!(deleted_at: Time.current)

      expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
    end

    # A suspension is an admin freezing the event out of the owner's hands.
    # Minting certificates in that state contradicts the point of the freeze.
    it "skips registrations on a suspended event" do
      event = past_event
      create(:registration, event: event, status: "confirmed", payment_status: "paid")
      event.update!(suspended_at: Time.current, suspension_reason: "under review")

      expect { described_class.perform_now }.not_to have_enqueued_job(RenderCertificateJob)
    end

    # Unlike a delete, a suspension is reversible — so nothing is lost by
    # waiting, and the next hourly run picks the event back up.
    it "picks them up again once the event is unsuspended" do
      event = past_event
      registration = create(:registration, event: event, status: "confirmed", payment_status: "paid")
      event.update!(suspended_at: Time.current)
      event.update!(suspended_at: nil)

      expect { described_class.perform_now }
        .to have_enqueued_job(RenderCertificateJob).with(registration.id)
    end
  end

  # ── The backfill cap ────────────────────────────────────────────────────────
  # There is no date cutoff on eligibility (product decision: every finished
  # event qualifies, however old), so the first runs after this job is enabled
  # face the entire history at once. Each render shells out to LibreOffice at
  # ~180 MB RSS, so an uncapped fan-out would starve the worker of the
  # registration and payment jobs people are actually waiting on.
  describe "MAX_PER_RUN" do
    it "enqueues no more than the cap in one run" do
      stub_const("#{described_class}::MAX_PER_RUN", 2)
      event = past_event
      3.times { create(:registration, event: event, status: "confirmed", payment_status: "paid") }

      expect { described_class.perform_now }
        .to have_enqueued_job(RenderCertificateJob).exactly(2).times
    end

    # Being hourly, a cap loses nothing — it defers. This is the half that
    # makes the cap safe rather than lossy.
    it "picks up the remainder on the next run" do
      stub_const("#{described_class}::MAX_PER_RUN", 2)
      event = past_event
      registrations = Array.new(3) do
        create(:registration, event: event, status: "confirmed", payment_status: "paid")
      end

      described_class.perform_now
      # Standing in for the renders the first run enqueued.
      enqueued_ids = enqueued_jobs.select { |j| j[:job] == RenderCertificateJob }
                                  .map { |j| j[:args].first }
      enqueued_ids.each { |id| create(:certificate, :with_file, registration_id: id) }
      clear_enqueued_jobs

      remaining = registrations.map(&:id) - enqueued_ids
      expect { described_class.perform_now }
        .to have_enqueued_job(RenderCertificateJob).with(remaining.first)
    end

    # Oldest-finished first, so a capped run drains in a predictable order
    # rather than whatever the query planner happened to return.
    #
    # Asserted against the enqueued list rather than with `have_enqueued_job`:
    # the matcher's count applies only to jobs matching its `.with`, so
    # `.with(oldest.id).once` would still pass if the newer event's render were
    # enqueued alongside it — which is the exact failure this example exists to
    # catch. Comparing the whole array pins both the count and the choice.
    it "takes the longest-finished event first" do
      stub_const("#{described_class}::MAX_PER_RUN", 1)
      older = past_event(start_at: 30.days.ago, end_at: 29.days.ago)
      oldest = create(:registration, event: older, status: "confirmed", payment_status: "paid")
      create(:registration, event: past_event, status: "confirmed", payment_status: "paid")

      described_class.perform_now

      enqueued_ids = enqueued_jobs.select { |j| j[:job] == RenderCertificateJob }
                                  .map { |j| j[:args].first }
      expect(enqueued_ids).to eq([ oldest.id ])
    end
  end
end
