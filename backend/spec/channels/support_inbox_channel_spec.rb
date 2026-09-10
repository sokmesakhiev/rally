require "rails_helper"

RSpec.describe SupportInboxChannel, type: :channel do
  # `connect` runs once per socket and there's no before_action equivalent, so
  # this check has to happen per subscription — it's the only thing standing
  # between an ordinary account and every support conversation on the platform.
  it "rejects an ordinary account" do
    stub_connection current_user: create(:user)

    subscribe

    expect(subscription).to be_rejected
  end

  it "admits an admin" do
    stub_connection current_user: create(:user, admin: true)

    subscribe

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(described_class::STREAM)
  end

  it "rejects a fresh subscription once the admin flag is revoked" do
    admin = create(:user, admin: true)
    stub_connection current_user: admin
    admin.update!(admin: false)

    subscribe

    expect(subscription).to be_rejected
  end

  # The above only covers *new* subscriptions. `subscribed` runs once and a
  # socket lives for hours, so an already-open one would keep streaming every
  # support conversation on the platform after its permission was revoked —
  # which is exactly the offboarding case. The periodic re-check is what
  # actually closes that, so drive it directly: channel specs have no event
  # loop, so the timer never fires on its own.
  describe "the periodic access re-check" do
    let(:admin) { create(:user, admin: true) }

    before do
      stub_connection current_user: admin
      subscribe
      expect(subscription).to have_stream_from(described_class::STREAM)
    end

    def run_access_recheck
      callback, = described_class.periodic_timers.first
      subscription.instance_exec(&callback)
    end

    it "is registered" do
      expect(described_class.periodic_timers).not_to be_empty
    end

    it "leaves a still-valid admin streaming" do
      run_access_recheck

      expect(subscription).to have_stream_from(described_class::STREAM)
    end

    it "stops an open subscription whose admin flag was revoked" do
      admin.update!(admin: false)

      run_access_recheck

      expect(subscription).not_to have_stream_from(described_class::STREAM)
    end

    # Reloading a destroyed account raises rather than returning nil, and this
    # runs on a timer thread where an exception is easy to lose.
    it "stops an open subscription whose account was destroyed" do
      admin.destroy

      expect { run_access_recheck }.not_to raise_error
      expect(subscription).not_to have_stream_from(described_class::STREAM)
    end
  end

  it "exposes no client-callable actions" do
    expect(described_class.action_methods.to_a).to be_empty
  end
end
