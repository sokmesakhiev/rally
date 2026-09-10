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

  before { stub_connection current_user: user }

  # The important half. Channel actions bypass rack-attack entirely — the
  # socket is hijacked at connect — so an ungated #echo would be an
  # unthrottleable INSERT path into solid_cable_messages for any logged-in
  # user. Off unless explicitly switched on.
  describe "when ENABLE_PING_CHANNEL is not set" do
    it "rejects the subscription" do
      subscribe

      expect(subscription).to be_rejected
    end
  end

  # Covers the re-check inside #echo. Rejecting in `subscribed` already stops
  # anyone subscribing while the flag is off — a rejected subscription can't be
  # performed against at all — so the case that needs its own test is the one
  # `subscribed` can't catch: a subscription opened while the flag was on, then
  # outliving it being turned off.
  it "stops echoing when the flag is turned off mid-subscription" do
    with_env("ENABLE_PING_CHANNEL" => "true") { subscribe }

    expect(subscription).to be_confirmed
    expect { perform :echo, "sent_at" => 1 }
      .not_to have_broadcasted_to("ping:#{user.id}")
  end

  describe "when enabled" do
    around { |example| with_env("ENABLE_PING_CHANNEL" => "true") { example.run } }

    it "streams from a stream keyed to the connected user, not a shared one" do
      subscribe

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("ping:#{user.id}")
    end

    it "echoes back through the pub/sub adapter" do
      subscribe

      expect { perform :echo, "sent_at" => 1234 }
        .to have_broadcasted_to("ping:#{user.id}")
    end
  end
end
