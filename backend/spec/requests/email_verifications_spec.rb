require "rails_helper"

RSpec.describe "Email Verifications API", type: :request do
  describe "POST /api/v1/email_verifications" do
    it "resends the verification email for the current user" do
      user = create(:user)

      expect {
        perform_enqueued_jobs { post "/api/v1/email_verifications", headers: auth_headers(user), as: :json }
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    it "requires authentication" do
      post "/api/v1/email_verifications", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "no-ops if already verified" do
      user = create(:user)
      user.verify_email!

      expect {
        perform_enqueued_jobs { post "/api/v1/email_verifications", headers: auth_headers(user), as: :json }
      }.not_to change { ActionMailer::Base.deliveries.count }
    end
  end

  describe "GET /api/v1/email_verifications/:token" do
    it "verifies the email for a valid token" do
      user = create(:user)

      get "/api/v1/email_verifications/#{user.email_verification_token}", as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.email_verified?).to be(true)
    end

    it "returns 422 for an invalid token" do
      get "/api/v1/email_verifications/bogus-token", as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
