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

    it "returns 401 without a token" do
      patch "/api/v1/profile", params: { profile: { display_name: "X" } }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
