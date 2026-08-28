require "rails_helper"

# organization-identity-tickets.md's Ticket J (#339) — the admin surface for
# organization moderation. Mirrors admin_spec.rb's event and user suspend
# sections, since it's the same concept one level up.
RSpec.describe "Admin organizations API", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:regular) { create(:user) }
  let(:organizer) { create(:user) }
  let!(:organization) { create(:organization, owner: organizer, name: "Phnom Penh Runners") }

  # ── Access ───────────────────────────────────────────────────────────────────
  describe "access control" do
    # 404 rather than 403 so the admin surface doesn't advertise itself —
    # same as every other route in this namespace.
    it "blocks every organization route for a non-admin" do
      get "/api/v1/admin/organizations", headers: auth_headers(regular), as: :json
      expect(response).to have_http_status(:not_found)

      post "/api/v1/admin/organizations/#{organization.id}/suspend",
           params: { reason: "Reported" }, headers: auth_headers(regular), as: :json
      expect(response).to have_http_status(:not_found)

      post "/api/v1/admin/organizations/#{organization.id}/unsuspend",
           headers: auth_headers(regular), as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "/api/v1/admin/organizations", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── Index ────────────────────────────────────────────────────────────────────
  describe "GET /api/v1/admin/organizations" do
    it "lists organizations with their owner and suspension state" do
      get "/api/v1/admin/organizations", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      row = json["organizations"].find { |o| o["id"] == organization.id }
      expect(row["name"]).to eq("Phnom Penh Runners")
      expect(row["owner"]["email"]).to eq(organizer.email)
      expect(row["suspended"]).to be(false)
    end

    # No `as: :json` on these two: on a GET it encodes params into a request
    # body instead of the query string, so the filter never reaches the action.
    it "filters by status" do
      other = create(:organization)
      organization.suspend!(reason: "Reported")

      get "/api/v1/admin/organizations", params: { status: "suspended" },
          headers: auth_headers(admin)

      ids = json["organizations"].map { |o| o["id"] }
      expect(ids).to include(organization.id)
      expect(ids).not_to include(other.id)
    end

    it "searches by name" do
      create(:organization, name: "Completely Unrelated")

      get "/api/v1/admin/organizations", params: { q: "Phnom" },
          headers: auth_headers(admin)

      expect(json["organizations"].map { |o| o["name"] }).to eq([ "Phnom Penh Runners" ])
    end

    # Staff need to see whether unsuspending here would actually restore the
    # organization, or whether the owner's account is what's holding it down.
    it "distinguishes a derived suspension from a direct one" do
      organizer.suspend!(reason: "Fraud")

      get "/api/v1/admin/organizations", headers: auth_headers(admin), as: :json

      row = json["organizations"].find { |o| o["id"] == organization.id }
      expect(row["suspended"]).to be(true)
      expect(row["suspended_directly"]).to be(false)
      expect(row["owner"]["suspended"]).to be(true)
    end
  end

  # ── Suspend ──────────────────────────────────────────────────────────────────
  describe "POST /api/v1/admin/organizations/:id/suspend" do
    let!(:event) { create(:event, :for_organization, presented_by: organization, creator: organizer) }

    it "suspends the organization and stores the reason" do
      post "/api/v1/admin/organizations/#{organization.id}/suspend",
           params: { reason: "Reported as fraudulent" },
           headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organization"]["suspended"]).to be(true)
      expect(json["organization"]["suspension_reason"]).to eq("Reported as fraudulent")
    end

    it "takes its events off public listings without unpublishing them" do
      post "/api/v1/admin/organizations/#{organization.id}/suspend",
           params: { reason: "Reported" }, headers: auth_headers(admin), as: :json

      expect(event.reload.suspended?).to be(true)
      expect(event.is_published).to be(true)
      expect(Event.publicly_visible).not_to include(event)
    end

    it "requires a reason" do
      post "/api/v1/admin/organizations/#{organization.id}/suspend",
           headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(organization.reload.suspended_directly?).to be(false)
    end

    it "rejects a blank reason" do
      post "/api/v1/admin/organizations/#{organization.id}/suspend",
           params: { reason: "" }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 404 for an unknown organization" do
      post "/api/v1/admin/organizations/#{SecureRandom.uuid}/suspend",
           params: { reason: "Reported" }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "records a queryable AdminAction" do
      expect {
        post "/api/v1/admin/organizations/#{organization.id}/suspend",
             params: { reason: "Reported" }, headers: auth_headers(admin), as: :json
      }.to change(AdminAction, :count).by(1)

      action = AdminAction.last
      expect(action.admin_id).to eq(admin.id)
      expect(action.action).to eq("suspend_organization")
      expect(action.target).to eq(organization)
    end

    it "emails the owner with the reason and a link to appeal" do
      expect {
        perform_enqueued_jobs do
          post "/api/v1/admin/organizations/#{organization.id}/suspend",
               params: { reason: "Reported as fraudulent" },
               headers: auth_headers(admin), as: :json
        end
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ organizer.email ])
      expect(mail.subject).to include("has been suspended")
      expect(mail.body.encoded).to include("Reported as fraudulent")
      expect(mail.body.encoded).to include(organization.slug)
    end

    it "still emails an owner with no display name set" do
      organizer.profile.update!(display_name: nil)

      expect {
        perform_enqueued_jobs do
          post "/api/v1/admin/organizations/#{organization.id}/suspend",
               params: { reason: "Reported" }, headers: auth_headers(admin), as: :json
        end
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
    end
  end

  # ── Unsuspend ────────────────────────────────────────────────────────────────
  describe "POST /api/v1/admin/organizations/:id/unsuspend" do
    let!(:event) { create(:event, :for_organization, presented_by: organization, creator: organizer) }

    it "clears the suspension and restores its events automatically" do
      organization.suspend!(reason: "Reported")

      post "/api/v1/admin/organizations/#{organization.id}/unsuspend",
           headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organization"]["suspended"]).to be(false)
      expect(event.reload.suspended?).to be(false)
      expect(Event.publicly_visible).to include(event)
    end

    # The case that makes deriving worth it over copying state down.
    it "leaves a directly-suspended event suspended" do
      event.suspend!(reason: "Its own problem")
      organization.suspend!(reason: "Separate problem")

      post "/api/v1/admin/organizations/#{organization.id}/unsuspend",
           headers: auth_headers(admin), as: :json

      expect(event.reload.suspended?).to be(true)
      expect(event.suspension_source).to eq("event")
    end

    it "is a harmless no-op on an organization that was never suspended" do
      post "/api/v1/admin/organizations/#{organization.id}/unsuspend",
           headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["organization"]["suspended"]).to be(false)
    end

    it "records a queryable AdminAction" do
      organization.suspend!(reason: "Reported")

      expect {
        post "/api/v1/admin/organizations/#{organization.id}/unsuspend",
             headers: auth_headers(admin), as: :json
      }.to change(AdminAction, :count).by(1)

      expect(AdminAction.last.action).to eq("unsuspend_organization")
    end

    it "does not email the owner" do
      organization.suspend!(reason: "Reported")

      expect {
        perform_enqueued_jobs do
          post "/api/v1/admin/organizations/#{organization.id}/unsuspend",
               headers: auth_headers(admin), as: :json
        end
      }.not_to change { ActionMailer::Base.deliveries.count }
    end

    it "returns 404 for an unknown organization" do
      post "/api/v1/admin/organizations/#{SecureRandom.uuid}/unsuspend",
           headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
