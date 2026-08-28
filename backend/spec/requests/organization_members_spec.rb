require "rails_helper"

# organization-identity-tickets.md's Ticket D (#333). Mirrors
# spec/requests/event_members_spec.rb's shape, with the differences the
# controller documents: the owner is a column rather than a row, and adding
# someone requires an existing account.
RSpec.describe "Organization members API", type: :request do
  let(:owner) { create(:user) }
  let(:admin) { create(:user) }
  let(:plain_member) { create(:user) }
  let(:stranger) { create(:user) }
  let!(:organization) { create(:organization, owner: owner) }
  let!(:admin_membership) do
    create(:organization_membership, organization: organization, user: admin, role: "admin")
  end
  let!(:member_membership) do
    create(:organization_membership, organization: organization, user: plain_member, role: "member")
  end

  # ── GET ──────────────────────────────────────────────────────────────────────
  describe "GET /api/v1/organizations/:slug/members" do
    it "lists the team, with the owner synthesized first" do
      get "/api/v1/organizations/#{organization.slug}/members",
          headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["members"].length).to eq(3)

      first = json["members"].first
      expect(first["role"]).to eq("owner")
      expect(first["user_id"]).to eq(owner.id)
      # id: nil marks it as not a real membership row — nothing to PATCH or
      # DELETE against.
      expect(first["id"]).to be_nil
    end

    it "is visible to a plain member" do
      get "/api/v1/organizations/#{organization.slug}/members",
          headers: auth_headers(plain_member), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["members"].length).to eq(3)
    end

    it "returns 404 to a stranger" do
      get "/api/v1/organizations/#{organization.slug}/members",
          headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "/api/v1/organizations/#{organization.slug}/members", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── POST ─────────────────────────────────────────────────────────────────────
  describe "POST /api/v1/organizations/:slug/members" do
    let(:newcomer) { create(:user, email: "colleague@example.com") }

    it "adds an existing user by email" do
      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: newcomer.email, role: "admin" } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(json["member"]["user_id"]).to eq(newcomer.id)
      expect(organization.reload.administered_by?(newcomer)).to be(true)
    end

    it "matches the email case-insensitively, ignoring surrounding whitespace" do
      # Referencing `newcomer` (a lazy let) is what actually creates the
      # account — hardcoding the address here would just test the
      # "no such user" path.
      submitted = "  #{newcomer.email.upcase}  "

      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: submitted, role: "member" } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(json["member"]["user_id"]).to eq(newcomer.id)
    end

    it "lets an admin add someone too" do
      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: newcomer.email, role: "member" } },
           headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:created)
    end

    it "returns 403 for a plain member" do
      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: newcomer.email, role: "member" } },
           headers: auth_headers(plain_member), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    # No invitation flow yet — see the controller's class comment.
    it "explains when there is no account for that email" do
      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: "nobody@example.com", role: "member" } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("user_not_found")
    end

    it "rejects someone already on the team" do
      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: admin.email, role: "member" } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    # Ownership is a column; a membership row for the owner would be a
    # second, contradictable source of truth.
    it "rejects adding the owner as a member" do
      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: owner.email, role: "admin" } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects an unknown role" do
      post "/api/v1/organizations/#{organization.slug}/members",
           params: { member: { email: newcomer.email, role: "superuser" } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ── PATCH ────────────────────────────────────────────────────────────────────
  describe "PATCH /api/v1/organizations/:slug/members/:id" do
    it "promotes a member to admin" do
      patch "/api/v1/organizations/#{organization.slug}/members/#{member_membership.id}",
            params: { membership: { role: "admin" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(member_membership.reload.role).to eq("admin")
    end

    it "lets an admin change roles too" do
      patch "/api/v1/organizations/#{organization.slug}/members/#{member_membership.id}",
            params: { membership: { role: "admin" } },
            headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 403 for a plain member" do
      patch "/api/v1/organizations/#{organization.slug}/members/#{admin_membership.id}",
            params: { membership: { role: "member" } },
            headers: auth_headers(plain_member), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(admin_membership.reload.role).to eq("admin")
    end

    it "returns 404 for a membership in another organization" do
      other = create(:organization_membership)

      patch "/api/v1/organizations/#{organization.slug}/members/#{other.id}",
            params: { membership: { role: "admin" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── DELETE ───────────────────────────────────────────────────────────────────
  describe "DELETE /api/v1/organizations/:slug/members/:id" do
    it "lets an admin remove a member" do
      delete "/api/v1/organizations/#{organization.slug}/members/#{member_membership.id}",
             headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(OrganizationMembership.exists?(member_membership.id)).to be(false)
    end

    # Otherwise a member has no way to leave except asking an admin.
    it "lets a plain member remove themselves" do
      delete "/api/v1/organizations/#{organization.slug}/members/#{member_membership.id}",
             headers: auth_headers(plain_member), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["message"]).to match(/left the organization/i)
    end

    it "does not let a member remove someone else" do
      delete "/api/v1/organizations/#{organization.slug}/members/#{admin_membership.id}",
             headers: auth_headers(plain_member), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(OrganizationMembership.exists?(admin_membership.id)).to be(true)
    end

    it "returns 404 to a stranger" do
      delete "/api/v1/organizations/#{organization.slug}/members/#{member_membership.id}",
             headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:not_found)
    end

    # The owner isn't a membership row, so there is structurally nothing to
    # DELETE — "the last owner can't leave" needs no guard. Handing over goes
    # through transfer_ownership.
    it "leaves the owner unreachable through this endpoint" do
      delete "/api/v1/organizations/#{organization.slug}/members/#{owner.id}",
             headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:not_found)
      expect(organization.reload.owner_id).to eq(owner.id)
    end
  end
end
