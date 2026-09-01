require "rails_helper"

RSpec.describe "Invitations API (accept)", type: :request do
  let(:owner) { create(:user) }
  let(:event) { create(:event, creator: owner) }

  # ── GET /api/v1/invitations/:token ───────────────────────────────────────────
  describe "GET /api/v1/invitations/:token" do
    it "returns landing info for a pending invitation" do
      invitation = create(:event_invitation, event: event, invited_by: owner, role: "manager")

      get "/api/v1/invitations/#{invitation.token}", as: :json

      expect(response).to have_http_status(:ok)
      expect(json["invitation"]["event_id"]).to eq(event.id)
      expect(json["invitation"]["event_title"]).to eq(event.title)
      expect(json["invitation"]["role"]).to eq("manager")
      expect(json["invitation"]["email"]).to eq(invitation.email)
      expect(json["invitation"]["valid"]).to be(true)
      expect(json["invitation"]["status"]).to eq("pending")
    end

    it "does not require authentication" do
      invitation = create(:event_invitation, event: event)
      get "/api/v1/invitations/#{invitation.token}", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "renders a clear invalid state for an expired token, not a generic error" do
      invitation = create(:event_invitation, :expired, event: event)

      get "/api/v1/invitations/#{invitation.token}", as: :json

      expect(response).to have_http_status(:ok)
      expect(json["invitation"]["valid"]).to be(false)
      expect(json["invitation"]["status"]).to eq("expired")
    end

    it "renders a clear invalid state for a revoked token, not a generic error" do
      invitation = create(:event_invitation, :revoked, event: event)

      get "/api/v1/invitations/#{invitation.token}", as: :json

      expect(response).to have_http_status(:ok)
      expect(json["invitation"]["valid"]).to be(false)
      expect(json["invitation"]["status"]).to eq("revoked")
    end

    it "returns 404 for an unknown token" do
      get "/api/v1/invitations/not-a-real-token", as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── POST /api/v1/invitations/:token/accept ───────────────────────────────────
  describe "POST /api/v1/invitations/:token/accept" do
    it "creates the membership, stamps the invitation accepted, and logs member_joined" do
      recipient = create(:user)
      invitation = create(:event_invitation, event: event, invited_by: owner, role: "manager", email: recipient.email)

      expect {
        post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(recipient), as: :json
      }.to change(EventMembership, :count).by(1).and change(EventActivity, :count).by(1)

      expect(response).to have_http_status(:ok)
      membership = EventMembership.last
      expect(membership.event).to eq(event)
      expect(membership.user).to eq(recipient)
      expect(membership.role).to eq("manager")
      expect(membership.invited_by).to eq(owner)
      expect(membership.accepted_at).to be_present

      expect(invitation.reload.accepted?).to be(true)

      activity = EventActivity.last
      expect(activity.action).to eq("member_joined")
      expect(activity.actor).to eq(recipient)
      expect(activity.event).to eq(event)
      expect(activity.metadata["role"]).to eq("manager")
    end

    # Simulates "a user with no Rally account can follow the link, sign up,
    # and land on the event as a member" — the signup step itself is
    # AuthController#signup, already covered by its own specs; this proves
    # only the accept half, once that fresh account exists.
    it "works for a brand-new account with no prior relationship to the event" do
      new_user = create(:user, email: "brandnew@example.com")
      invitation = create(:event_invitation, event: event, invited_by: owner, email: "brandnew@example.com")

      post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(new_user), as: :json

      expect(response).to have_http_status(:ok)
      expect(new_user.member_events).to include(event)
    end

    it "is idempotent — accepting twice creates no duplicate membership and doesn't error" do
      recipient = create(:user)
      invitation = create(:event_invitation, event: event, email: recipient.email)

      post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(recipient), as: :json
      expect(response).to have_http_status(:ok)

      expect {
        post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(recipient), as: :json
      }.not_to change(EventMembership, :count)

      expect(response).to have_http_status(:ok)
    end

    it "does not double-log member_joined on a repeat accept" do
      recipient = create(:user)
      invitation = create(:event_invitation, event: event, email: recipient.email)
      post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(recipient), as: :json

      expect {
        post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(recipient), as: :json
      }.not_to change(EventActivity, :count)
    end

    it "returns 422 with code: invitation_email_mismatch when the signed-in account doesn't match, and creates nothing" do
      recipient = create(:user)
      wrong_user = create(:user)
      invitation = create(:event_invitation, event: event, email: recipient.email)

      expect {
        post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(wrong_user), as: :json
      }.not_to change(EventMembership, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("invitation_email_mismatch")
      expect(json["error"]).to include(recipient.email)
    end

    it "returns 422 with code: invitation_invalid for a revoked invitation" do
      recipient = create(:user)
      invitation = create(:event_invitation, :revoked, event: event, email: recipient.email)

      post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(recipient), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("invitation_invalid")
    end

    it "returns 422 with code: invitation_invalid for an expired invitation" do
      recipient = create(:user)
      invitation = create(:event_invitation, :expired, event: event, email: recipient.email)

      post "/api/v1/invitations/#{invitation.token}/accept", headers: auth_headers(recipient), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("invitation_invalid")
    end

    it "returns 401 without a token" do
      invitation = create(:event_invitation, event: event)
      post "/api/v1/invitations/#{invitation.token}/accept", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an unknown invitation token" do
      post "/api/v1/invitations/not-a-real-token/accept", headers: auth_headers(create(:user)), as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
