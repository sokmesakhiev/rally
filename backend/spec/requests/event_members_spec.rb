require "rails_helper"

RSpec.describe "Event Members API", type: :request do
  let(:owner) { create(:user) }
  let(:event) { create(:event, creator: owner) }
  let(:other) { create(:user) }

  # ── GET /api/v1/events/:event_id/members ─────────────────────────────────────
  describe "GET /api/v1/events/:event_id/members" do
    it "includes the owner, synthesized with role: owner and no membership id" do
      get "/api/v1/events/#{event.id}/members", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      owner_entry = json["members"].find { |m| m["user_id"] == owner.id }
      expect(owner_entry["role"]).to eq("owner")
      expect(owner_entry["id"]).to be_nil
    end

    it "lists an accepted member with role, display name, avatar, and joined_at" do
      member = create(:user)
      member.profile.update!(display_name: "Dara Kim")
      membership = create(:event_membership, event: event, user: member, role: "manager")

      get "/api/v1/events/#{event.id}/members", headers: auth_headers(owner), as: :json

      entry = json["members"].find { |m| m["user_id"] == member.id }
      expect(entry["id"]).to eq(membership.id)
      expect(entry["role"]).to eq("manager")
      expect(entry["display_name"]).to eq("Dara Kim")
      expect(entry["joined_at"]).to be_present
    end

    it "is visible to any member, not just the owner" do
      viewer = create(:user)
      create(:event_membership, event: event, user: viewer, role: "viewer")

      get "/api/v1/events/#{event.id}/members", headers: auth_headers(viewer), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for a stranger" do
      get "/api/v1/events/#{event.id}/members", headers: auth_headers(other), as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without a token" do
      get "/api/v1/events/#{event.id}/members", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── PATCH /api/v1/events/:event_id/members/:id ───────────────────────────────
  describe "PATCH /api/v1/events/:event_id/members/:id" do
    it "lets the owner promote a Viewer to Manager" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      patch "/api/v1/events/#{event.id}/members/#{membership.id}",
            params: { membership: { role: "manager" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(membership.reload.role).to eq("manager")
    end

    it "lets the owner demote back" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "manager")

      patch "/api/v1/events/#{event.id}/members/#{membership.id}",
            params: { membership: { role: "viewer" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(membership.reload.role).to eq("viewer")
    end

    it "logs an EventActivity when the role actually changes" do
      member = create(:user)
      member.profile.update!(display_name: "Dara Kim")
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      expect {
        patch "/api/v1/events/#{event.id}/members/#{membership.id}",
              params: { membership: { role: "manager" } },
              headers: auth_headers(owner), as: :json
      }.to change(EventActivity, :count).by(1)

      activity = EventActivity.last
      expect(activity.action).to eq("change_member_role")
      expect(activity.actor).to eq(owner)
      expect(activity.metadata["user_id"]).to eq(member.id)
      expect(activity.metadata["member_name"]).to eq("Dara Kim")
      expect(activity.metadata["member_email"]).to eq(member.email)
      expect(activity.metadata["from"]).to eq("viewer")
      expect(activity.metadata["to"]).to eq("manager")
    end

    it "does not log an EventActivity when the submitted role matches the current one" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "manager")

      expect {
        patch "/api/v1/events/#{event.id}/members/#{membership.id}",
              params: { membership: { role: "manager" } },
              headers: auth_headers(owner), as: :json
      }.not_to change(EventActivity, :count)
    end

    it "returns 422 for an unknown role (schema)" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      patch "/api/v1/events/#{event.id}/members/#{membership.id}",
            params: { membership: { role: "co-owner" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 403 for a Manager attempting to change someone's role" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")
      other_member = create(:user)
      membership = create(:event_membership, event: event, user: other_member, role: "viewer")

      patch "/api/v1/events/#{event.id}/members/#{membership.id}",
            params: { membership: { role: "manager" } },
            headers: auth_headers(manager), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(membership.reload.role).to eq("viewer")
    end

    it "returns 403 for a stranger" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      patch "/api/v1/events/#{event.id}/members/#{membership.id}",
            params: { membership: { role: "manager" } },
            headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for an unknown member id" do
      patch "/api/v1/events/#{event.id}/members/#{SecureRandom.uuid}",
            params: { membership: { role: "manager" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without a token" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      patch "/api/v1/events/#{event.id}/members/#{membership.id}",
            params: { membership: { role: "manager" } }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── DELETE /api/v1/events/:event_id/members/:id ──────────────────────────────
  describe "DELETE /api/v1/events/:event_id/members/:id" do
    it "lets the owner remove a member" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "manager")

      delete "/api/v1/events/#{event.id}/members/#{membership.id}", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(EventMembership.exists?(membership.id)).to be(false)
    end

    it "logs an EventActivity for remove_member, marking it as not a self-removal" do
      member = create(:user)
      member.profile.update!(display_name: "Dara Kim")
      membership = create(:event_membership, event: event, user: member, role: "manager")

      expect {
        delete "/api/v1/events/#{event.id}/members/#{membership.id}", headers: auth_headers(owner), as: :json
      }.to change(EventActivity, :count).by(1)

      activity = EventActivity.last
      expect(activity.action).to eq("remove_member")
      expect(activity.actor).to eq(owner)
      expect(activity.metadata["user_id"]).to eq(member.id)
      expect(activity.metadata["member_name"]).to eq("Dara Kim")
      expect(activity.metadata["member_email"]).to eq(member.email)
     expect(activity.metadata["self_removal"]).to be(false)
    end

    it "lets a member remove themselves (leave)" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      delete "/api/v1/events/#{event.id}/members/#{membership.id}", headers: auth_headers(member), as: :json

      expect(response).to have_http_status(:ok)
      expect(EventMembership.exists?(membership.id)).to be(false)
    end

    it "logs self_removal: true when a member leaves on their own" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      delete "/api/v1/events/#{event.id}/members/#{membership.id}", headers: auth_headers(member), as: :json

      activity = EventActivity.last
      expect(activity.action).to eq("remove_member")
      expect(activity.actor).to eq(member)
      expect(activity.metadata["self_removal"]).to be(true)
    end

    it "returns 403 for a Manager trying to remove someone else, and removes nothing" do
      manager = create(:user)
      create(:event_membership, event: event, user: manager, role: "manager")
      other_member = create(:user)
      membership = create(:event_membership, event: event, user: other_member, role: "viewer")

      delete "/api/v1/events/#{event.id}/members/#{membership.id}", headers: auth_headers(manager), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(EventMembership.exists?(membership.id)).to be(true)
    end

    it "returns 403 for a stranger" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")

      delete "/api/v1/events/#{event.id}/members/#{membership.id}", headers: auth_headers(other), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    # The acceptance criterion this pins: "A removed member immediately
    # loses access to every gated endpoint" — no session/token caching, the
    # very next request from the removed member is denied.
    it "immediately revokes access to a gated endpoint once removed" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "manager")
      registration = create(:registration, event: event)

      delete "/api/v1/events/#{event.id}/members/#{membership.id}", headers: auth_headers(owner), as: :json
      expect(response).to have_http_status(:ok)

      patch "/api/v1/registrations/#{registration.id}",
            params: { registration: { payment_status: "paid", amount_paid_cents: 0 } },
            headers: auth_headers(member), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for an unknown member id" do
      delete "/api/v1/events/#{event.id}/members/#{SecureRandom.uuid}", headers: auth_headers(owner), as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without a token" do
      member = create(:user)
      membership = create(:event_membership, event: event, user: member, role: "viewer")
      delete "/api/v1/events/#{event.id}/members/#{membership.id}", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
