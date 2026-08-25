require "rails_helper"

RSpec.describe NotifyEventDetailsChangedJob do
  include ActiveJob::TestHelper

  let(:event) { create(:event) }
  let(:registration) { create(:registration, event: event) }
  let(:changes) { { price_cents: { from: 0, to: 2500 } } }

  it "emails every active registrant" do
    registration

    expect {
      perform_enqueued_jobs { described_class.perform_now(event, changes) }
    }.to change { ActionMailer::Base.deliveries.count }.by(1)

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([ registration.user.email ])
    expect(mail.subject).to include("Details changed")
  end

  it "does not email a cancelled registration" do
    registration.update!(status: "cancelled")

    expect {
      perform_enqueued_jobs { described_class.perform_now(event, changes) }
    }.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "does not email a registrant who opted out" do
    registration.user.profile.update!(notify_event_details_changed: false)

    expect {
      perform_enqueued_jobs { described_class.perform_now(event, changes) }
    }.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "does nothing when there are no changes" do
    registration

    expect {
      perform_enqueued_jobs { described_class.perform_now(event, {}) }
    }.not_to change { ActionMailer::Base.deliveries.count }
  end
end
