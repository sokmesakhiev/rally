require "rails_helper"

RSpec.describe "Auth API", type: :request do
  let(:password) { "password123" }

  # ── POST /api/v1/auth/signup ─────────────────────────────────────────────────
  describe "POST /api/v1/auth/signup" do
    let(:valid_params) { { email: "new@example.com", password: password } }

    it "creates a user and returns a token" do
      post "/api/v1/auth/signup", params: valid_params, as: :json

      expect(response).to have_http_status(:created)
      expect(json["token"]).to be_present
      expect(json["user"]["email"]).to eq("new@example.com")
    end

    it "creates a profile for the new user" do
      post "/api/v1/auth/signup", params: valid_params, as: :json

      user = User.find(json["user"]["id"])
      expect(user.profile).to be_present
    end

    it "stores an optional display_name on the profile" do
      post "/api/v1/auth/signup",
           params: valid_params.merge(display_name: "Alex Runner"),
           as: :json

      expect(json["user"]["display_name"]).to eq("Alex Runner")
    end

    it "returns 422 for a duplicate email" do
      create(:user, email: "new@example.com")
      post "/api/v1/auth/signup", params: valid_params, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
    end

    it "returns 422 for a short password" do
      post "/api/v1/auth/signup",
           params: { email: "x@x.com", password: "short" },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 for an invalid email" do
      post "/api/v1/auth/signup",
           params: { email: "not-valid", password: password },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "sends a verification email and marks the account unverified" do
      expect {
        perform_enqueued_jobs { post "/api/v1/auth/signup", params: valid_params, as: :json }
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(json["user"]["email_verified"]).to be(false)
    end
  end

  # ── POST /api/v1/auth/signin ─────────────────────────────────────────────────
  describe "POST /api/v1/auth/signin" do
    let!(:user) { create(:user, password: password) }

    it "returns a token for valid credentials" do
      post "/api/v1/auth/signin",
           params: { email: user.email, password: password },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(json["token"]).to be_present
      expect(json["user"]["id"]).to eq(user.id)
    end

    it "is case-insensitive for email" do
      post "/api/v1/auth/signin",
           params: { email: user.email.upcase, password: password },
           as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 401 for a wrong password" do
      post "/api/v1/auth/signin",
           params: { email: user.email, password: "wrongpass" },
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json["token"]).to be_nil
    end

    it "returns 401 for an unknown email" do
      post "/api/v1/auth/signin",
           params: { email: "ghost@example.com", password: password },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── GET /api/v1/auth/me ──────────────────────────────────────────────────────
  describe "GET /api/v1/auth/me" do
    let!(:user) { create(:user) }

    it "returns the current user when authenticated" do
      get "/api/v1/auth/me", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["id"]).to eq(user.id)
      expect(json["user"]["email"]).to eq(user.email)
    end

    it "returns 401 with no token" do
      get "/api/v1/auth/me", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with an invalid token" do
      get "/api/v1/auth/me",
          headers: { "Authorization" => "Bearer invalid.token.here" },
          as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
