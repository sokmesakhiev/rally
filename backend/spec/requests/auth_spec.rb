require "rails_helper"

RSpec.describe "Auth API", type: :request do
  let(:password) { "password123" }

  # ── POST /api/v1/auth/signup ─────────────────────────────────────────────────
  describe "POST /api/v1/auth/signup" do
    let(:valid_params) { { email: "new@example.com", password: password, terms_accepted: true } }

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

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to be_present
    end

    it "returns 422 for a short password" do
      post "/api/v1/auth/signup",
           params: { email: "x@x.com", password: "short" },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 for an invalid email" do
      post "/api/v1/auth/signup",
           params: { email: "not-valid", password: password },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "sends a verification email and marks the account unverified" do
      expect {
        perform_enqueued_jobs { post "/api/v1/auth/signup", params: valid_params, as: :json }
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(json["user"]["email_verified"]).to be(false)
    end

    it "returns 422 when email is missing entirely (schema)" do
      post "/api/v1/auth/signup", params: { password: password }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to be_present
    end

    it "returns 422 when password is missing entirely (schema)" do
      post "/api/v1/auth/signup", params: { email: "new@example.com" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
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

        expect(response).to have_http_status(:unprocessable_content)
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

    # See event-freeze-and-terms-tickets.md's Ticket F.
    describe "Terms of Service acceptance" do
      it "rejects signup with 422 when terms_accepted is missing entirely" do
        params = valid_params.except(:terms_accepted)

        expect {
          post "/api/v1/auth/signup", params: params, as: :json
        }.not_to change(User, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["code"]).to eq("terms_not_accepted")
      end

      it "rejects signup with 422 when terms_accepted is explicitly false" do
        expect {
          post "/api/v1/auth/signup", params: valid_params.merge(terms_accepted: false), as: :json
        }.not_to change(User, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(json["code"]).to eq("terms_not_accepted")
      end

      it "creates the account and stamps terms_accepted_at/terms_version when accepted" do
        post "/api/v1/auth/signup", params: valid_params, as: :json

        expect(response).to have_http_status(:created)
        user = User.find(json["user"]["id"])
        expect(user.terms_accepted_at).to be_present
        expect(user.terms_version).to eq(TermsOfService::CURRENT_VERSION)
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

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to be_present
    end

    it "returns 422 when password is missing entirely (schema)" do
      post "/api/v1/auth/signin", params: { email: user.email }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
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

    # See event-freeze-and-terms-tickets.md's Ticket H — this one-click flow
    # never shows a terms checkbox, so the frontend has to prompt separately
    # (gated on this being null) and call POST /auth/accept_terms.
    it "leaves a brand-new account's terms_accepted_at nil" do
      stub_google_payload(google_payload)
      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      expect(json["user"]["terms_accepted_at"]).to be_nil
      expect(User.find(json["user"]["id"]).terms_accepted_at).to be_nil
    end

    it "does not retroactively stamp terms_accepted_at for a returning Google user" do
      stub_google_payload(google_payload)
      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      expect(json["user"]["terms_accepted_at"]).to be_nil
    end

    it "does not touch an existing password account's terms_accepted_at when linking Google" do
      existing = create(:user, email: "runner@example.com")
      existing.update!(terms_accepted_at: 3.days.ago, terms_version: "2026-01-01")
      stub_google_payload(google_payload)

      post "/api/v1/auth/google", params: { id_token: "fake" }, as: :json

      existing.reload
      expect(existing.terms_accepted_at).to be_present
      expect(existing.terms_version).to eq("2026-01-01")
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

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to be_present
    end
  end

  # ── POST /api/v1/auth/accept_terms ───────────────────────────────────────────
  # See event-freeze-and-terms-tickets.md's Ticket H.
  describe "POST /api/v1/auth/accept_terms" do
    it "stamps terms_accepted_at/terms_version for a brand-new Google account" do
      user = create(:user, terms_accepted_at: nil, terms_version: nil)

      post "/api/v1/auth/accept_terms", headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["terms_accepted_at"]).to be_present
      user.reload
      expect(user.terms_accepted_at).to be_present
      expect(user.terms_version).to eq(TermsOfService::CURRENT_VERSION)
    end

    it "is idempotent — calling it again just re-stamps rather than erroring" do
      user = create(:user, terms_accepted_at: 1.day.ago, terms_version: TermsOfService::CURRENT_VERSION)
      headers = auth_headers(user)

      post "/api/v1/auth/accept_terms", headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      post "/api/v1/auth/accept_terms", headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end

    it "returns 401 without a token" do
      post "/api/v1/auth/accept_terms", as: :json
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

    it "returns 401 for a still-unexpired token belonging to a since-deleted account" do
      user = create(:user)
      headers = auth_headers(user)
      user.discard!

      get "/api/v1/auth/me", headers: headers, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json["code"]).to eq("account_deleted")
    end
  end

  # ── PATCH /api/v1/auth/password ──────────────────────────────────────────────
  describe "PATCH /api/v1/auth/password" do
    let!(:user) { create(:user, password: password) }

    it "updates the password when the current one is correct" do
      patch "/api/v1/auth/password",
            params: { current_password: password, new_password: "newpassword123",
                      new_password_confirmation: "newpassword123" },
            headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.authenticate("newpassword123")).to eq(user)
    end

    it "rejects an incorrect current password without changing anything" do
      patch "/api/v1/auth/password",
            params: { current_password: "wrongpass", new_password: "newpassword123",
                      new_password_confirmation: "newpassword123" },
            headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.authenticate(password)).to eq(user)
    end

    it "rejects a mismatched confirmation" do
      patch "/api/v1/auth/password",
            params: { current_password: password, new_password: "newpassword123",
                      new_password_confirmation: "somethingelse" },
            headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a new password shorter than 8 characters" do
      patch "/api/v1/auth/password",
            params: { current_password: password, new_password: "short",
                      new_password_confirmation: "short" },
            headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 401 without a token" do
      patch "/api/v1/auth/password",
            params: { current_password: password, new_password: "newpassword123",
                      new_password_confirmation: "newpassword123" },
            as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── PATCH /api/v1/auth/email ─────────────────────────────────────────────────
  describe "PATCH /api/v1/auth/email" do
    let!(:user) { create(:user, password: password) }

    it "changes the email immediately and drops email_verified back to false" do
      user.verify_email!
      expect(user.email_verified?).to be(true)

      patch "/api/v1/auth/email",
            params: { current_password: password, new_email: "new-address@example.com" },
            headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["email"]).to eq("new-address@example.com")
      expect(json["user"]["email_verified"]).to be(false)
      expect(user.reload.email).to eq("new-address@example.com")
    end

    it "sends a new verification email to the new address" do
      expect {
        perform_enqueued_jobs do
          patch "/api/v1/auth/email",
                params: { current_password: password, new_email: "new-address@example.com" },
                headers: auth_headers(user), as: :json
        end
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(ActionMailer::Base.deliveries.last.to).to eq([ "new-address@example.com" ])
    end

    it "rejects an incorrect current password" do
      patch "/api/v1/auth/email",
            params: { current_password: "wrongpass", new_email: "new-address@example.com" },
            headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.email).not_to eq("new-address@example.com")
    end

    it "rejects an email already used by another account" do
      create(:user, email: "taken@example.com")

      patch "/api/v1/auth/email",
            params: { current_password: password, new_email: "taken@example.com" },
            headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 401 without a token" do
      patch "/api/v1/auth/email",
            params: { current_password: password, new_email: "new-address@example.com" },
            as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── DELETE /api/v1/auth/account ──────────────────────────────────────────────
  describe "DELETE /api/v1/auth/account" do
    let!(:user) { create(:user, password: password) }

    it "anonymizes the account when the current password is correct" do
      headers = auth_headers(user)

      delete "/api/v1/auth/account",
             params: { current_password: password },
             headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.discarded?).to be(true)
    end

    it "rejects an incorrect current password without deleting anything" do
      delete "/api/v1/auth/account",
             params: { current_password: "wrongpass" },
             headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.discarded?).to be(false)
    end

    it "blocks deletion while the user organizes an event with a paid registration" do
      event = create(:event, creator: user)
      create(:registration, event: event, payment_status: "paid")

      delete "/api/v1/auth/account",
             params: { current_password: password },
             headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("has_paid_events")
      expect(user.reload.discarded?).to be(false)
    end

    it "allows deletion when the user organizes an event with only unpaid registrations" do
      event = create(:event, creator: user)
      create(:registration, event: event, payment_status: "unpaid")

      delete "/api/v1/auth/account",
             params: { current_password: password },
             headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.discarded?).to be(true)
    end

    it "returns 401 without a token" do
      delete "/api/v1/auth/account", params: { current_password: password }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
