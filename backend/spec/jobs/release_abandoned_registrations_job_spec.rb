require "rails_helper"

RSpec.describe ReleaseAbandonedRegistrationsJob, type: :job do
  it "delegates to the service" do
    allow(Registrations::ReleaseAbandoned).to receive(:call)
      .and_return(Registrations::ReleaseAbandoned::Result.new(released: 2, promoted: 1))

    described_class.perform_now

    expect(Registrations::ReleaseAbandoned).to have_received(:call)
  end

  it "runs end to end without stubs" do
    event = create(:event, :paid, capacity: 5)
    registration = create(:registration, event: event, payment_status: "unpaid")
    registration.update_columns(created_at: 3.hours.ago)

    described_class.perform_now

    expect(registration.reload).to be_discarded
  end

  # config/recurring.yml names this class as a string; a rename that missed the
  # schedule would fail silently in production and nowhere else.
  it "is the class config/recurring.yml schedules" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"))

    expect(schedule.dig("production", "release_abandoned_registrations", "class"))
      .to eq(described_class.name)
  end
end
