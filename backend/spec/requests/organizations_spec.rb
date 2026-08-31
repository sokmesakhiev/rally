require "rails_helper"

# organization-identity-tickets.md's Ticket D (#333). The management surface —
# the public organizer page is Ticket F (#335) and is specced separately.
RSpec.describe "Organizations API", type: :request do
  let(:owner) { create(:user) }
  let(:admin) { create(:user) }
  let(:plain_member) { create(:user) }
  let(:stranger) { create(:user) }
  let!(:organization) { create(:organization, :branded, owner: owner, name: "Phnom Penh Runners") }

  before do
    create(:organization_membership, organization: organization, user: admin, role: "admin")
    create(:organization_membership, organization: organization, user: plain_member, role: "member")
  end

  # ── GET /api/v1/organizations ────────────────────────────────────────────────
  describe "GET /api/v1/organizations" do
    it "lists organizations the caller owns" do
      get "/api/v1/organizations", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organizations"].map { |o| o["id"] }).to include(organization.id)
      expect(json["organizations"].first["role"]).to eq("owner")
    end

    it "lists organizations the caller administers" do
      get "/api/v1/organizations", headers: auth_headers(admin), as: :json

      expect(json["organizations"].map { |o| o["id"] }).to include(organization.id)
      expect(json["organizations"].first["role"]).to eq("admin")
    end

    # Plain membership grants no authority, so it doesn't belong in the org
    # switcher — see Organization#administered_by?.
    it "excludes organizations where the caller is only a plain member" do
      get "/api/v1/organizations", headers: auth_headers(plain_member), as: :json

      expect(json["organizations"]).to be_empty
    end

    it "is empty for someone with no organizations" do
      get "/api/v1/organizations", headers: auth_headers(stranger), as: :json

      expect(json["organizations"]).to be_empty
    end

    it "excludes deleted organizations" do
      organization.discard!

      get "/api/v1/organizations", headers: auth_headers(owner), as: :json

      expect(json["organizations"]).to be_empty
    end

    it "requires authentication" do
      get "/api/v1/organizations", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── POST /api/v1/organizations ───────────────────────────────────────────────
  describe "POST /api/v1/organizations" do
    let(:valid_params) do
      { organization: { name: "Siem Reap Striders", description: "A club.", contact_email: "hi@example.com" } }
    end

    it "creates an organization owned by the caller" do
      post "/api/v1/organizations", params: valid_params, headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:created)
      expect(json["organization"]["name"]).to eq("Siem Reap Striders")
      expect(json["organization"]["owner_id"]).to eq(stranger.id)
      expect(json["organization"]["role"]).to eq("owner")
    end

    it "generates a slug from the name" do
      post "/api/v1/organizations", params: valid_params, headers: auth_headers(stranger), as: :json

      expect(json["organization"]["slug"]).to eq("siem-reap-striders")
    end

    # A user may run their own series and also help run a club.
    it "lets one user own several organizations" do
      post "/api/v1/organizations", params: valid_params, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(owner.owned_organizations.count).to eq(2)
    end

    it "returns 422 without a name" do
      post "/api/v1/organizations",
           params: { organization: { description: "No name" } },
           headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 for a malformed website" do
      post "/api/v1/organizations",
           params: { organization: { name: "X", website: "example.com" } },
           headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    # Accepting a slug would let a caller squat a URL that can then never be
    # corrected, since slugs are immutable once generated.
    it "ignores an attempt to choose the slug" do
      post "/api/v1/organizations",
           params: { organization: { name: "Chosen Name", slug: "something-else" } },
           headers: auth_headers(stranger), as: :json

      expect(json["organization"]["slug"]).to eq("chosen-name")
    end

    # Self-verifying would defeat the entire trust signal the badge carries.
    it "ignores an attempt to self-verify" do
      post "/api/v1/organizations",
           params: { organization: { name: "Sneaky", verified_at: Time.current.iso8601 } },
           headers: auth_headers(stranger), as: :json

      expect(json["organization"]["verified"]).to be(false)
    end
  end

  # ── GET /api/v1/organizations/:slug ──────────────────────────────────────────
  describe "GET /api/v1/organizations/:slug" do
    it "returns the management payload to the owner" do
      get "/api/v1/organizations/#{organization.slug}", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organization"]["name"]).to eq("Phnom Penh Runners")
      expect(json["organization"]["role"]).to eq("owner")
    end

    it "is readable by a plain member" do
      get "/api/v1/organizations/#{organization.slug}", headers: auth_headers(plain_member), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organization"]["role"]).to eq("member")
    end

    # 404, not 403 — don't confirm the slug exists to someone unrelated.
    it "returns 404 to a stranger" do
      get "/api/v1/organizations/#{organization.slug}", headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an unknown slug" do
      get "/api/v1/organizations/nope", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "never exposes the plaintext PayWay key" do
      organization.update!(payway_merchant_id: "m_123", payway_api_key: "secret_abcdef1234")

      get "/api/v1/organizations/#{organization.slug}", headers: auth_headers(owner), as: :json

      expect(response.body).not_to include("secret_abcdef1234")
      expect(json["organization"]["payway_api_key_masked"]).to eq("••••••••1234")
      expect(json["organization"]["payway_configured"]).to be(true)
    end
  end

  # ── PATCH /api/v1/organizations/:slug ────────────────────────────────────────
  describe "PATCH /api/v1/organizations/:slug" do
    it "lets the owner update identity and branding" do
      patch "/api/v1/organizations/#{organization.slug}",
            params: { organization: { name: "Renamed", brand_color: "#ff0000" } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organization"]["name"]).to eq("Renamed")
    end

    it "lets an admin update identity too" do
      patch "/api/v1/organizations/#{organization.slug}",
            params: { organization: { description: "Edited by admin" } },
            headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 403 for a plain member" do
      patch "/api/v1/organizations/#{organization.slug}",
            params: { organization: { name: "Nope" } },
            headers: auth_headers(plain_member), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for a stranger" do
      patch "/api/v1/organizations/#{organization.slug}",
            params: { organization: { name: "Nope" } },
            headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:not_found)
    end

    # Renaming must never move the URL — links already shared stay valid.
    it "keeps the slug when the name changes" do
      expect {
        patch "/api/v1/organizations/#{organization.slug}",
              params: { organization: { name: "Completely Different" } },
              headers: auth_headers(owner), as: :json
      }.not_to change { organization.reload.slug }

      expect(response).to have_http_status(:ok)
    end

    describe "PayWay credentials" do
      let(:payway_params) do
        { organization: { payway_merchant_id: "m_123", payway_api_key: "secret_abcdef1234" } }
      end

      it "lets the owner connect a PayWay account" do
        patch "/api/v1/organizations/#{organization.slug}",
              params: payway_params, headers: auth_headers(owner), as: :json

        expect(response).to have_http_status(:ok)
        expect(organization.reload.payway_configured?).to be(true)
      end

      # These decide where other people's registration money lands, so they
      # stay owner-only even though admins may edit everything else.
      it "refuses an admin, rather than silently ignoring the fields" do
        patch "/api/v1/organizations/#{organization.slug}",
              params: payway_params, headers: auth_headers(admin), as: :json

        expect(response).to have_http_status(:forbidden)
        expect(json["code"]).to eq("owner_required")
        expect(organization.reload.payway_configured?).to be(false)
      end

      it "rejects a merchant id without an api key" do
        patch "/api/v1/organizations/#{organization.slug}",
              params: { organization: { payway_merchant_id: "m_123" } },
              headers: auth_headers(owner), as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  # ── DELETE /api/v1/organizations/:slug ───────────────────────────────────────
  describe "DELETE /api/v1/organizations/:slug" do
    it "soft-deletes an organization with no events" do
      delete "/api/v1/organizations/#{organization.slug}", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(organization.reload.discarded?).to be(true)
      expect(Organization.exists?(organization.id)).to be(true)
    end

    # Otherwise a live event's "Presented by" block points at nothing.
    it "refuses while the organization still presents events" do
      create(:event, :for_organization, presented_by: organization)

      delete "/api/v1/organizations/#{organization.slug}", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("organization_has_events")
      expect(organization.reload.discarded?).to be(false)
    end

    it "allows deletion once its only event is discarded" do
      event = create(:event, :for_organization, presented_by: organization)
      event.discard!

      delete "/api/v1/organizations/#{organization.slug}", headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "returns 403 for an admin" do
      delete "/api/v1/organizations/#{organization.slug}", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(organization.reload.discarded?).to be(false)
    end

    it "returns 404 for a stranger" do
      delete "/api/v1/organizations/#{organization.slug}", headers: auth_headers(stranger), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── POST /api/v1/organizations/:slug/transfer_ownership ──────────────────────
  describe "POST /api/v1/organizations/:slug/transfer_ownership" do
    it "hands ownership to an existing admin" do
      post "/api/v1/organizations/#{organization.slug}/transfer_ownership",
           params: { user_id: admin.id }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(organization.reload.owner_id).to eq(admin.id)
    end

    # Losing all access to an organization you just handed over is rarely
    # what anyone means, and you can't re-add yourself once you're off it.
    it "demotes the previous owner to admin rather than dropping them" do
      post "/api/v1/organizations/#{organization.slug}/transfer_ownership",
           params: { user_id: admin.id }, headers: auth_headers(owner), as: :json

      expect(organization.reload.administered_by?(owner)).to be(true)
      expect(organization.owner?(owner)).to be(false)
    end

    it "leaves the new owner without a leftover membership row" do
      post "/api/v1/organizations/#{organization.slug}/transfer_ownership",
           params: { user_id: admin.id }, headers: auth_headers(owner), as: :json

      expect(organization.organization_memberships.where(user_id: admin.id)).to be_empty
      expect(organization.reload.team).to contain_exactly(owner, admin, plain_member)
    end

    # Ownership carries the payment credentials and the right to delete, so
    # it can't go to someone who has never been on the team.
    it "refuses transfer to a plain member" do
      post "/api/v1/organizations/#{organization.slug}/transfer_ownership",
           params: { user_id: plain_member.id }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("admin_required")
      expect(organization.reload.owner_id).to eq(owner.id)
    end

    it "refuses transfer to a stranger" do
      post "/api/v1/organizations/#{organization.slug}/transfer_ownership",
           params: { user_id: stranger.id }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(organization.reload.owner_id).to eq(owner.id)
    end

    it "returns 403 when an admin tries to transfer" do
      post "/api/v1/organizations/#{organization.slug}/transfer_ownership",
           params: { user_id: admin.id }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(organization.reload.owner_id).to eq(owner.id)
    end
  end
end
