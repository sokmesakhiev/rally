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

    it "returns 422 when email is missing entirely (schema)" do
      post "/api/v1/auth/signup", params: { password: password }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
    end

    it "returns 422 when password is missing entirely (schema)" do
      post "/api/v1/auth/signup", params: { email: "new@example.com" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
    end

    # RecaptchaVerifier itself is stubbed here (not the network call it makes)
    # — these specs are about AuthController#signup's own handling of the
    # result, not RecaptchaVerifier's decision logic (see
    # spec/services/recaptcha_verifier_spec.rb for that). With
    # RECAPTCHA_SECRET_KEY unset in test (the default), every other example
    # in this file already exercises the "unconfigured, always passes" path
    # without needing to stub anything.
    describe "captcha protection" do
      it "rejects signup with 422 when the captcha check fails" do
        allow(RecaptchaVerifier).to receive(:verify)
          .and_return(RecaptchaVerifier::Result.new(success?: false, score: 0.1, reason: "low_score"))

        expect {
          post "/api/v1/auth/signup", params: valid_params.merge(recaptcha_token: "tok"), as: :json
        }.not_to change(User, :count)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json["code"]).to eq("recaptcha_failed")
      end

      it "creates the account when the captcha check passes" do
        allow(RecaptchaVerifier).to receive(:verify)
          .and_return(RecaptchaVerifier::Result.new(success?: true, score: 0.9, reason: nil))

        post "/api/v1/auth/signup", params: valid_params.merge(recaptcha_token: "tok"), as: :json

        expect(response).to have_http_status(:created)
        expect(json["token"]).to be_present
      end

      it "passes the token and signup action through to the verifier" do
        expect(RecaptchaVerifier).to receive(:verify)
          .with("tok", action: "signup", remote_ip: anything)
          .and_return(RecaptchaVerifier::Result.new(success?: true, score: 0.9, reason: nil))

        post "/api/v1/auth/signup", params: valid_params.merge(recaptcha_token: "tok"), as: :json
      end
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

    it "returns 422 when email is missing entirely (schema)" do
      post "/api/v1/auth/signin", params: { password: password }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
    end

    it "returns 422 when password is missing entirely (schema)" do
      post "/api/v1/auth/signin", params: { email: user.email }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
    end
  end

  # ── POST /api/v1/auth/google ─────────────────────────────────────────────────
  # Google::Auth::IDTokens.verify_oidc makes a real network call to fetch
  # Google's signing keys, so it's stubbed here — these specs are about our
  # own find-or-create/link/sign-in logic, not Google's token format.
  describe "POST /api/v1/auth/google" do
    def stub_google_payload(payload)
      allow(Google::Auth::IDTokens).to receive(:verify_oidc).and_return(payload.stringify_keys)
    end

    let(:google_payload) do
      { sub: "google-uid-123", email: "runner@example.com", email_verified: true, name: "Alex Runner" }
    end

    it "creates a new account on first sign-in and returns a token" do
      stub_google_payload(google_payload)
      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json["token"]).to be_present
      expect(json["user"]["email"]).to eq("runner@example.com")
      expect(json["user"]["email_verified"]).to be(true)
      expect(json["user"]["display_name"]).to eq("Alex Runner")

      user = User.find(json["user"]["id"])
      expect(user.google_uid).to eq("google-uid-123")
      expect(user.provider).to eq("google")
    end

    it "signs in the same user on a later visit without creating a duplicate" do
      stub_google_payload(google_payload)
      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json
      first_user_id = json["user"]["id"]

      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["id"]).to eq(first_user_id)
      expect(User.where(google_uid: "google-uid-123").count).to eq(1)
    end

    it "links an existing password account by matching email instead of duplicating it" do
      existing = create(:user, email: "runner@example.com")
      stub_google_payload(google_payload)

      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["id"]).to eq(existing.id)
      expect(existing.reload.google_uid).to eq("google-uid-123")
      expect(existing.email_verified?).to be(true)
    end

    it "returns 401 for a token that fails verification" do
      allow(Google::Auth::IDTokens).to receive(:verify_oidc)
        .and_raise(Google::Auth::IDTokens::SignatureError, "bad signature")

      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json["error"]).to be_present
    end

    it "returns 422 when id_token is missing entirely (schema), without calling the verifier" do
      expect(Google::Auth::IDTokens).not_to receive(:verify_oidc)

      post "/api/v1/auth/google", params: {}, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
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
