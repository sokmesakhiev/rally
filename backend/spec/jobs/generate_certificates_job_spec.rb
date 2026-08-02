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
end
