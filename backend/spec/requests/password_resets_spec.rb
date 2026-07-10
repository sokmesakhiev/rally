require "rails_helper"

RSpec.describe "Password Resets API", type: :request do
  describe "POST /api/v1/password_resets" do
    it "sends a reset email for a known address and returns 200" do
      user = create(:user)

      expect {
        perform_enqueued_jobs { post "/api/v1/password_resets", params: { email: user.email }, as: :json }
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(user.reload.password_reset_token).to be_present
    end

    it "returns 200 without leaking whether the email exists" do
      post "/api/v1/password_resets", params: { email: "ghost@example.com" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json["message"]).to be_present
    end
  end

  describe "PATCH /api/v1/password_resets/:token" do
    it "resets the password for a valid token" do
      user = create(:user, password: "oldpassword")
      user.generate_password_reset_token!

      patch "/api/v1/password_resets/#{user.password_reset_token}",
            params: { password: "newpassword123", password_confirmation: "newpassword123" },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["token"]).to be_present
      expect(user.reload.authenticate("newpassword123")).to eq(user)
    end

    it "returns 422 for an invalid token" do
      patch "/api/v1/password_resets/bogus-token",
            params: { password: "newpassword123", password_confirmation: "newpassword123" },
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 for an expired token" do
      user = create(:user)
      user.generate_password_reset_token!
      user.update_column(:password_reset_sent_at, 3.hours.ago)

      patch "/api/v1/password_resets/#{user.password_reset_token}",
            params: { password: "newpassword123", password_confirmation: "newpassword123" },
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 when passwords don't match" do
      user = create(:user)
      user.generate_password_reset_token!

      patch "/api/v1/password_resets/#{user.password_reset_token}",
            params: { password: "newpassword123", password_confirmation: "different" },
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
