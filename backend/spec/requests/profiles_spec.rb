require "rails_helper"

RSpec.describe "Profiles API", type: :request do
  let(:user) { create(:user) }

  # ── GET /api/v1/profile ──────────────────────────────────────────────────────
  describe "GET /api/v1/profile" do
    it "returns the current user's profile" do
      user.profile.update!(display_name: "Alex Runner")

      get "/api/v1/profile", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["profile"]["user_id"]).to eq(user.id)
      expect(json["profile"]["display_name"]).to eq("Alex Runner")
    end

    it "returns 401 without a token" do
      get "/api/v1/profile", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── PATCH /api/v1/profile ────────────────────────────────────────────────────
  describe "PATCH /api/v1/profile" do
    it "updates display_name" do
      patch "/api/v1/profile",
            params: { profile: { display_name: "New Name" } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["profile"]["display_name"]).to eq("New Name")
      expect(user.profile.reload.display_name).to eq("New Name")
    end

    it "updates avatar_url" do
      patch "/api/v1/profile",
            params: { profile: { avatar_url: "https://example.com/avatar.png" } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["profile"]["avatar_url"]).to eq("https://example.com/avatar.png")
    end

    it "updates phone" do
      patch "/api/v1/profile",
            params: { profile: { phone: "012 345 678" } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["profile"]["phone"]).to eq("012 345 678")
      expect(user.profile.reload.phone).to eq("012 345 678")
    end

    it "rejects a phone number already used by another account" do
      other = create(:user)
      other.profile.update!(phone: "012345678")

      patch "/api/v1/profile",
            params: { profile: { phone: "012345678" } },
            headers: auth_headers(user),
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "surfaces email_auto_generated so the frontend can nudge for a real email" do
      checkout = Registrations::GuestCheckout.call(email: nil, phone: "012345678", name: "Dara Kim")
      # auth_headers signs in with a known password ("password123") — a
      # guest-checkout account has a random, never-shown one (see
      # Registrations::GuestCheckout), so build the token directly instead
      # of going through the real signin flow.
      token = JsonWebToken.encode(user_id: checkout.user.id)

      get "/api/v1/profile", headers: { "Authorization" => "Bearer #{token}" }, as: :json

      expect(json["profile"]["email_auto_generated"]).to be(true)
    end

    it "returns 401 without a token" do
      patch "/api/v1/profile", params: { profile: { display_name: "X" } }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    # ── PayWay credentials ─────────────────────────────────────────────────────
    # TRANSITIONAL, removed with Ticket G (#336). Credentials live on
    # Organization since #331, but this endpoint still proxies reads and writes
    # so the existing payment-settings form keeps working until #336 moves that
    # UI. These specs pin the proxy; when #336 lands they move to the
    # organization endpoint.
    context "PayWay credentials (proxied to the organization)" do
      let!(:organization) { create(:organization, owner: user) }

      it "saves PayWay credentials and returns a masked key, never the plaintext" do
        patch "/api/v1/profile",
              params: { profile: { payway_merchant_id: "merchant_123", payway_api_key: "secret_abcdef1234" } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(json["profile"]["payway_merchant_id"]).to eq("merchant_123")
        expect(json["profile"]["payway_configured"]).to eq(true)
        expect(json["profile"]["payway_api_key_masked"]).to eq("••••••••1234")
        expect(response.body).not_to include("secret_abcdef1234")
      end

      # The whole point of the move: the credentials land on the organization,
      # which is what AbaPayway::Client.for_event reads.
      it "writes them to the organization, not the profile" do
        patch "/api/v1/profile",
              params: { profile: { payway_merchant_id: "merchant_123", payway_api_key: "secret_abcdef1234" } },
              headers: auth_headers(user),
              as: :json

        expect(organization.reload.payway_api_key).to eq("secret_abcdef1234")
        expect(organization.payway_merchant_id).to eq("merchant_123")
      end

      it "leaves the saved api key untouched when the field is omitted" do
        organization.update!(payway_merchant_id: "merchant_123", payway_api_key: "secret_abcdef1234")

        patch "/api/v1/profile",
              params: { profile: { display_name: "New Name" } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(organization.reload.payway_api_key).to eq("secret_abcdef1234")
        expect(user.profile.reload.display_name).to eq("New Name")
      end

      it "disconnects PayWay when both fields are submitted blank" do
        organization.update!(payway_merchant_id: "merchant_123", payway_api_key: "secret_abcdef1234")

        patch "/api/v1/profile",
              params: { profile: { payway_merchant_id: "", payway_api_key: "" } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(json["profile"]["payway_configured"]).to eq(false)
        expect(organization.reload.payway_api_key).to be_nil
      end

      it "rejects a merchant id without an api key" do
        patch "/api/v1/profile",
              params: { profile: { payway_merchant_id: "merchant_123" } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(organization.reload.payway_merchant_id).to be_nil
      end

      it "reads back the organization's saved credentials on GET" do
        organization.update!(payway_merchant_id: "merchant_123", payway_api_key: "secret_abcdef1234")

        get "/api/v1/profile", headers: auth_headers(user), as: :json

        expect(json["profile"]["payway_merchant_id"]).to eq("merchant_123")
        expect(json["profile"]["payway_configured"]).to be(true)
      end

      it "reports refund capability only once the RSA key is set" do
        organization.update!(payway_merchant_id: "m", payway_api_key: "k")
        get "/api/v1/profile", headers: auth_headers(user), as: :json
        expect(json["profile"]["payway_refund_configured"]).to be(false)

        organization.update!(payway_rsa_public_key: "-----BEGIN PUBLIC KEY-----")
        get "/api/v1/profile", headers: auth_headers(user), as: :json
        expect(json["profile"]["payway_refund_configured"]).to be(true)
      end

      # Refusing to guess beats settling a club's income into the wrong
      # merchant account.
      it "refuses to write when the caller owns more than one organization" do
        create(:organization, owner: user)

        patch "/api/v1/profile",
              params: { profile: { payway_merchant_id: "merchant_123", payway_api_key: "secret_abcdef1234" } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["code"]).to eq("organization_required")
        expect(organization.reload.payway_merchant_id).to be_nil
      end

      it "does not block a non-PayWay profile update for a multi-organization owner" do
        create(:organization, owner: user)

        patch "/api/v1/profile",
              params: { profile: { display_name: "Still Fine" } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(user.profile.reload.display_name).to eq("Still Fine")
      end
    end

    context "PayWay credentials when the caller owns no organization" do
      it "explains that an organization is needed first" do
        patch "/api/v1/profile",
              params: { profile: { payway_merchant_id: "merchant_123", payway_api_key: "secret_abcdef1234" } },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["code"]).to eq("organization_required")
      end

      it "still reports PayWay as unconfigured on GET rather than erroring" do
        get "/api/v1/profile", headers: auth_headers(user), as: :json

        expect(response).to have_http_status(:ok)
        expect(json["profile"]["payway_configured"]).to be(false)
        expect(json["profile"]["payway_merchant_id"]).to be_nil
      end
    end
  end
end
