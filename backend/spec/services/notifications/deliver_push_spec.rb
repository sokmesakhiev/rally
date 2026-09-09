require "rails_helper"

RSpec.describe Notifications::DeliverPush do
  let(:user) { create(:user) }

  def deliver(target = user)
    described_class.call(user: target, title: "Hi", body: "There", url: "/dashboard")
  end

  describe "when no VAPID keypair is configured" do
    # The default everywhere except a configured production: development,
    # test, CI, and any deploy where push hasn't been set up.
    before { allow(Notifications::Vapid).to receive(:configured?).and_return(false) }

    it "uses the null adapter rather than raising" do
      create(:push_subscription, user: user)

      expect { deliver }.not_to raise_error
    end

    it "never reaches the web-push gem" do
      create(:push_subscription, user: user)
      expect(described_class.adapter).to be_a(Notifications::PushAdapters::Null)

      deliver
    end
  end

  describe "when VAPID is configured" do
    before do
      allow(Notifications::Vapid).to receive_messages(
        configured?: true, public_key: "pub", private_key: "priv", subject: "mailto:a@b.c"
      )
    end

    it "sends to every live subscription the user has" do
      create_list(:push_subscription, 2, user: user)
      allow(WebPush).to receive(:payload_send)

      result = deliver

      expect(WebPush).to have_received(:payload_send).twice
      expect(result.delivered).to eq(2)
    end

    it "skips subscriptions already known to be dead" do
      create(:push_subscription, user: user, expired_at: 1.day.ago)
      allow(WebPush).to receive(:payload_send)

      deliver

      expect(WebPush).not_to have_received(:payload_send)
    end

    it "doesn't send to another user's devices" do
      create(:push_subscription, user: create(:user))
      allow(WebPush).to receive(:payload_send)

      deliver

      expect(WebPush).not_to have_received(:payload_send)
    end

    it "carries the payload the service worker expects" do
      create(:push_subscription, user: user)
      allow(WebPush).to receive(:payload_send)

      described_class.call(user: user, title: "T", body: "B", url: "/dashboard", tag: "x")

      expect(WebPush).to have_received(:payload_send).with(
        hash_including(message: { title: "T", body: "B", url: "/dashboard", tag: "x" }.to_json)
      )
    end

    describe "a subscription the browser has thrown away" do
      it "is expired rather than retried" do
        subscription = create(:push_subscription, user: user)
        # Built with .allocate rather than .new: WebPush's error classes
        # descend from ResponseError, whose initializer wants a real HTTP
        # response object. All this spec cares about is that the adapter
        # rescues this class, so constructing a faithful response would be
        # coupling the test to gem internals for no benefit.
        allow(WebPush).to receive(:payload_send)
          .and_raise(WebPush::ExpiredSubscription.allocate)

        result = deliver

        expect(subscription.reload).to be_expired
        expect(result.expired).to eq(1)
      end
    end

    # One bad endpoint among many must not stop the rest — which is exactly
    # what a single raise partway through the loop would do.
    it "keeps going after one device fails" do
      create_list(:push_subscription, 3, user: user)
      call_count = 0
      allow(WebPush).to receive(:payload_send) do
        call_count += 1
        raise WebPush::Error, "push service exploded" if call_count == 2
      end

      result = deliver

      expect(call_count).to eq(3)
      expect(result.delivered).to eq(2)
    end

    # A notification failing must never fail the thing that triggered it.
    it "does not raise when the push service is unreachable" do
      create(:push_subscription, user: user)
      allow(WebPush).to receive(:payload_send).and_raise(WebPush::Error, "unreachable")

      expect { deliver }.not_to raise_error
    end
  end

  describe "a user with nothing subscribed" do
    it "returns an empty result without touching the adapter" do
      result = deliver

      expect(result.delivered).to eq(0)
    end
  end
end
