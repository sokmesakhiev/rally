require "rails_helper"

RSpec.describe "Push subscriptions API", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  let(:endpoint) { "https://fcm.googleapis.com/fcm/send/abc123" }
  let(:valid_payload) do
    { subscription: { endpoint: endpoint, p256dh_key: "pub-key", auth_key: "auth-key" } }
  end

  describe "GET /api/v1/push/vapid_public_key" do
    it "is reachable without a session — the browser needs it before subscribing" do
      allow(Notifications::Vapid).to receive_messages(configured?: true, public_key: "pub")

      get "/api/v1/push/vapid_public_key"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("enabled" => true, "public_key" => "pub")
    end

    # The shape the frontend keys off to hide the feature entirely rather than
    # prompt for a permission nothing can act on.
    it "reports enabled: false with no key when VAPID isn't configured" do
      allow(Notifications::Vapid).to receive(:configured?).and_return(false)

      get "/api/v1/push/vapid_public_key"

      expect(response.parsed_body).to eq("enabled" => false, "public_key" => nil)
    end
  end

  describe "POST /api/v1/push/subscriptions" do
    it "requires a session" do
      post "/api/v1/push/subscriptions", params: valid_payload, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a subscription for the caller" do
      expect {
        post "/api/v1/push/subscriptions", params: valid_payload, as: :json, headers: auth_headers(user)
      }.to change(PushSubscription, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(PushSubscription.last.user).to eq(user)
    end

    it "records the user agent so a person can tell their devices apart" do
      post "/api/v1/push/subscriptions", params: valid_payload, as: :json,
        headers: auth_headers(user).merge("User-Agent" => "Firefox/1.0")

      expect(PushSubscription.last.user_agent).to eq("Firefox/1.0")
    end

    # Browsers hand back the same endpoint when you subscribe again with the
    # same VAPID key. Without this, one person gets every notification twice.
    it "is idempotent — re-subscribing updates rather than duplicating" do
      post "/api/v1/push/subscriptions", params: valid_payload, as: :json, headers: auth_headers(user)

      expect {
        post "/api/v1/push/subscriptions",
          params: { subscription: valid_payload[:subscription].merge(auth_key: "rotated") },
          as: :json, headers: auth_headers(user)
      }.not_to change(PushSubscription, :count)

      expect(PushSubscription.last.auth_key).to eq("rotated")
    end

    it "revives a subscription that had been marked dead" do
      create(:push_subscription, user: user, endpoint: endpoint, expired_at: 1.day.ago)

      post "/api/v1/push/subscriptions", params: valid_payload, as: :json, headers: auth_headers(user)

      expect(PushSubscription.find_by(endpoint: endpoint).expired_at).to be_nil
    end

    describe "when the endpoint already belongs to someone else" do
      let!(:existing) { create(:push_subscription, user: other_user, endpoint: endpoint) }

      # Endpoints are per browser, not per user: on a shared device the second
      # person to sign in legitimately owns this row. The transfer is real
      # behaviour — what matters is that it's deliberate rather than a silent
      # side effect of an unscoped finder.
      it "transfers the device to the caller" do
        post "/api/v1/push/subscriptions", params: valid_payload, as: :json, headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        expect(PushSubscription.where(endpoint: endpoint).count).to eq(1)
        expect(PushSubscription.find_by(endpoint: endpoint).user).to eq(user)
      end

      it "leaves the previous owner's other devices alone" do
        keeper = create(:push_subscription, user: other_user)

        post "/api/v1/push/subscriptions", params: valid_payload, as: :json, headers: auth_headers(user)

        expect(keeper.reload).to be_persisted
        expect(other_user.push_subscriptions.reload).to contain_exactly(keeper)
      end
    end

    describe "schema" do
      it "rejects a missing endpoint" do
        post "/api/v1/push/subscriptions",
          params: { subscription: { p256dh_key: "a", auth_key: "b" } },
          as: :json, headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
      end

      # The endpoint is used to make an outbound request from our own server,
      # so an arbitrary scheme would be a request-forgery primitive.
      it "rejects a non-https endpoint" do
        post "/api/v1/push/subscriptions",
          params: { subscription: valid_payload[:subscription].merge(endpoint: "http://evil.test/x") },
          as: :json, headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "rejects a non-URL endpoint" do
        post "/api/v1/push/subscriptions",
          params: { subscription: valid_payload[:subscription].merge(endpoint: "file:///etc/passwd") },
          as: :json, headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe "POST /api/v1/push/unsubscribe" do
    let!(:subscription) { create(:push_subscription, user: user, endpoint: endpoint) }

    it "requires a session" do
      post "/api/v1/push/unsubscribe", params: { endpoint: endpoint }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    # A POST specifically because a body on DELETE isn't reliably parsed end to
    # end. This spec is what proves the endpoint actually arrives.
    it "removes the caller's subscription" do
      expect {
        post "/api/v1/push/unsubscribe", params: { endpoint: endpoint }, as: :json,
          headers: auth_headers(user)
      }.to change(PushSubscription, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it "400s when no endpoint is given, rather than silently deleting nothing" do
      post "/api/v1/push/unsubscribe", params: {}, as: :json, headers: auth_headers(user)

      expect(response).to have_http_status(:bad_request)
    end

    # Knowing an endpoint must not be enough to silence someone else's device.
    it "will not remove another user's subscription" do
      victim = create(:push_subscription, user: other_user)

      post "/api/v1/push/unsubscribe", params: { endpoint: victim.endpoint }, as: :json,
        headers: auth_headers(user)

      expect(response).to have_http_status(:no_content)
      expect(victim.reload).to be_persisted
    end

    # 204 either way — reporting 404 would leak whether an endpoint is registered.
    it "succeeds for an endpoint that was never subscribed" do
      post "/api/v1/push/unsubscribe",
        params: { endpoint: "https://fcm.googleapis.com/fcm/send/never-seen" },
        as: :json, headers: auth_headers(user)

      expect(response).to have_http_status(:no_content)
    end
  end
end
