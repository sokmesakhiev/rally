require "rails_helper"

RSpec.describe "Event Invitations API", type: :request do
  let(:owner)  { create(:user) }
  let(:event)  { create(:event, creator: owner) }
  let(:other)  { create(:user) }

  # ── POST /api/v1/events/:event_id/invitations ────────────────────────────────
  describe "POST /api/v1/events/:event_id/invitations" do
    let(:valid_params) { { email: "newmember@example.com", role: "manager" } }

    it "sends exactly one email with a working tokenized link for a brand-new email" do
      expect {
        perform_enqueued_jobs do
          post "/api/v1/events/#{event.id}/invitations", params: valid_params, headers: auth_headers(owner), as: :json
        end
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(response).to have_http_status(:created)
      invitation = EventInvitation.last
      expect(invitation.email).to eq("newmember@example.com")
      expect(invitation.role).to eq("manager")
      expect(invitation.invited_by).to eq(owner)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ "newmember@example.com" ])
      # .decoded, not .body.encoded — the raw encoded body is
      # quoted-printable and soft-wraps long lines with "=\r\n", which would
      # split a URL this long mid-string and fail a plain #include? check.
      expect(mail.text_part.decoded).to include("/events/#{event.id}/invitations/#{invitation.token}")
    end

    it "normalizes the email's case before storing and matching" do
      post "/api/v1/events/#{event.id}/invitations",
           params: { email: "Mixed.Case@Example.com", role: "viewer" },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(EventInvitation.last.email).to eq("mixed.case@example.com")
    end

    it "logs an EventActivity for invite_member" do
      expect {
        post "/api/v1/events/#{event.id}/invitations", params: valid_params, headers: auth_headers(owner), as: :json
      }.to change(EventActivity, :count).by(1)

      activity = EventActivity.last
      expect(activity.action).to eq("invite_member")
      expect(activity.actor).to eq(owner)
      expect(activity.metadata["email"]).to eq("newmember@example.com")
      expect(activity.metadata["role"]).to eq("manager")
    end

    it "returns 422 with code: self_invite when inviting the owner's own email, and sends nothing" do
      expect {
        post "/api/v1/events/#{event.id}/invitations",
             params: { email: owner.email, role: "manager" },
             headers: auth_headers(owner), as: :json
      }.not_to change { ActionMailer::Base.deliveries.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("self_invite")
    end

    it "returns 422 with code: already_member and sends nothing for an existing member's email" do
      member = create(:user)
      create(:event_membership, event: event, user: member, role: "viewer")

      expect {
        perform_enqueued_jobs do
          post "/api/v1/events/#{event.id}/invitations",
               params: { email: member.email, role: "manager" },
               headers: auth_headers(owner), as: :json
        end
      }.not_to change { ActionMailer::Base.deliveries.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("already_member")
      expect(EventInvitation.count).to eq(0)
    end

    it "does not treat an unrelated event's membership as already_member" do
      member = create(:user)
      other_event = create(:event)
      create(:event_membership, event: other_event, user: member, role: "manager")

      post "/api/v1/events/#{event.id}/invitations",
           params: { email: member.email, role: "manager" },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
    end

    it "returns 422 with code: invite_pending for a duplicate pending invite, and sends nothing" do
      create(:event_invitation, event: event, email: "pending@example.com")

      expect {
        perform_enqueued_jobs do
          post "/api/v1/events/#{event.id}/invitations",
               params: { email: "pending@example.com", role: "viewer" },
               headers: auth_headers(owner), as: :json
        end
      }.not_to change { ActionMailer::Base.deliveries.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("invite_pending")
    end

    it "allows re-inviting an email whose earlier invitation was revoked" do
      create(:event_invitation, :revoked, event: event, email: "again@example.com")

      post "/api/v1/events/#{event.id}/invitations",
           params: { email: "again@example.com", role: "viewer" },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
    end

    it "allows re-inviting an email whose earlier invitation expired" do
      create(:event_invitation, :expired, event: event, email: "expired@example.com")

      post "/api/v1/events/#{event.id}/invitations",
           params: { email: "expired@example.com", role: "viewer" },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
    end

    it "returns 422 for an unknown role (schema)" do
      post "/api/v1/events/#{event.id}/invitations",
           params: { email: "x@example.com", role: "co-owner" },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when email is missing entirely (schema)" do
      post "/api/v1/events/#{event.id}/invitations",
           params: { role: "manager" },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 403 for a Manager member — member management is owner-only" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")

      post "/api/v1/events/#{event.id}/invitations", params: valid_params, headers: auth_headers(manager), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 for a stranger" do
      post "/api/v1/events/#{event.id}/invitations", params: valid_params, headers: auth_headers(other), as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without a token" do
      post "/api/v1/events/#{event.id}/invitations", params: valid_params, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an unknown event" do
      post "/api/v1/events/#{SecureRandom.uuid}/invitations",
           params: valid_params, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── GET /api/v1/events/:event_id/invitations ─────────────────────────────────
  describe "GET /api/v1/events/:event_id/invitations" do
    it "lists only pending invitations, for the owner" do
      pending_invite = create(:event_invitation, event: event)
      create(:event_invitation, :accepted, event: event)
      create(:event_invitation, :revoked, event: event)
      create(:event_invitation, :expired, event: event)

      get "/api/v1/events/#{event.id}/invitations", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      ids = json["invitations"].map { |i| i["id"] }
      expect(ids).to eq([ pending_invite.id ])
    end

    it "returns 403 for a Manager" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")

      get "/api/v1/events/#{event.id}/invitations", headers: auth_headers(manager), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 for a stranger" do
      get "/api/v1/events/#{event.id}/invitations", headers: auth_headers(other), as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without a token" do
      get "/api/v1/events/#{event.id}/invitations", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── DELETE /api/v1/events/:event_id/invitations/:id ──────────────────────────
  describe "DELETE /api/v1/events/:event_id/invitations/:id" do
    it "revokes the invitation so its token no longer resolves" do
      invitation = create(:event_invitation, event: event)

      delete "/api/v1/events/#{event.id}/invitations/#{invitation.id}", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(invitation.reload.revoked?).to be(true)
      expect(EventInvitation.find_by_valid_token(invitation.token)).to be_nil
    end

    it "logs an EventActivity for revoke_invitation" do
      invitation = create(:event_invitation, event: event)

      expect {
        delete "/api/v1/events/#{event.id}/invitations/#{invitation.id}", headers: auth_headers(owner), as: :json
      }.to change(EventActivity, :count).by(1)

      activity = EventActivity.last
      expect(activity.action).to eq("revoke_invitation")
      expect(activity.actor).to eq(owner)
      expect(activity.metadata["email"]).to eq(invitation.email)
    end

    it "returns 403 for a Manager" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")
      invitation = create(:event_invitation, event: event)

      delete "/api/v1/events/#{event.id}/invitations/#{invitation.id}", headers: auth_headers(manager), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(invitation.reload.revoked?).to be(false)
    end

    it "returns 403 for a stranger" do
      invitation = create(:event_invitation, event: event)

      delete "/api/v1/events/#{event.id}/invitations/#{invitation.id}", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for an unknown invitation id" do
      delete "/api/v1/events/#{event.id}/invitations/#{SecureRandom.uuid}", headers: auth_headers(owner), as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without a token" do
      invitation = create(:event_invitation, event: event)
      delete "/api/v1/events/#{event.id}/invitations/#{invitation.id}", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
