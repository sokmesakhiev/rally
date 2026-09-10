require "rails_helper"

RSpec.describe PingChannel, type: :channel do
  # Same local-helper shape as spec/services/notifications/vapid_spec.rb.
  def with_env(vars)
    original = ENV.to_hash
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    ENV.replace(original)
  end

  let(:user) { create(:user) }
  let(:admin) { create(:user, admin: true) }

  # The important half. Channel actions bypass rack-attack entirely — the
  # socket is hijacked at connect — so an ungated #echo would be an
  # unthrottleable INSERT path into solid_cable_messages for any logged-in
  # user.
  describe "an ordinary account" do
    before { stub_connection current_user: user }

    it "is rejected" do
      subscribe

      expect(subscription).to be_rejected
    end
  end

  # The normal path for the Ticket 0 smoke run: no task-definition surgery, and
  # unlike the env var it never widens the surface beyond people who can
  # already suspend users and delete events.
  describe "an admin" do
    before { stub_connection current_user: admin }

    it "streams from a stream keyed to the connected user, not a shared one" do
      subscribe

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("ping:#{admin.id}")
    end

    it "echoes back through the pub/sub adapter" do
      subscribe

      expect { perform :echo, "sent_at" => 1234 }
        .to have_broadcasted_to("ping:#{admin.id}")
    end
  end

  # The escape hatch for a load run needing several non-admin accounts, since
  # the cable-ticket throttle is keyed per user.
  describe "when ENABLE_PING_CHANNEL is set" do
    before { stub_connection current_user: user }

    around { |example| with_env("ENABLE_PING_CHANNEL" => "true") { example.run } }

    it "admits an ordinary account too" do
      subscribe

      expect(subscription).to be_confirmed
    end
  end

  # Covers the re-check inside #echo. Rejecting in `subscribed` already stops
  # anyone subscribing while it's closed — a rejected subscription can't be
  # performed against at all — so the case needing its own test is the one
  # `subscribed` can't catch: a subscription that outlives its own permission.
  it "stops echoing once the admin flag is revoked mid-subscription" do
    stub_connection current_user: admin
    subscribe
    expect(subscription).to be_confirmed

    admin.update!(admin: false)

    expect { perform :echo, "sent_at" => 1 }
      .not_to have_broadcasted_to("ping:#{admin.id}")
  end
end
