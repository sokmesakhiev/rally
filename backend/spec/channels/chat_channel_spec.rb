require "rails_helper"

RSpec.describe ChatChannel, type: :channel do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  before { stub_connection current_user: user }

  it "streams from the caller's own stream" do
    subscribe

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("support:user:#{user.id}")
  end

  # The safety property worth pinning: the stream name comes from the
  # connection, not from params, so there is nothing a caller can pass to reach
  # someone else's messages. If anyone ever adds a conversation_id parameter,
  # this is the guard that should stop them without thinking it through.
  it "ignores any attempt to name a different stream" do
    subscribe(user_id: other_user.id, conversation_id: SecureRandom.uuid)

    expect(subscription).to have_stream_from("support:user:#{user.id}")
    expect(subscription).not_to have_stream_from("support:user:#{other_user.id}")
  end

  # Receive-only. Every write goes through the throttled REST endpoint, which
  # is what makes rack-attack's blindness to channel actions a non-issue here.
  it "exposes no client-callable actions" do
    actions = described_class.action_methods.to_a

    expect(actions).to be_empty
  end
end
