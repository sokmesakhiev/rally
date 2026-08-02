require "rails_helper"

RSpec.describe "Admin API", type: :request do
  let(:admin)   { create(:user, admin: true) }
  let(:regular) { create(:user) }

  # ── Access control ───────────────────────────────────────────────────────────
  describe "access control" do
    it "returns 404 (not 403) for a non-admin, so the surface doesn't advertise itself" do
      get "/api/v1/admin/users", headers: auth_headers(regular), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 with no token" do
      get "/api/v1/admin/users", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "allows an admin through" do
      get "/api/v1/admin/users", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "blocks every admin route for a non-admin" do
      event = create(:event)

      get "/api/v1/admin/events",                       headers: auth_headers(regular), as: :json
      expect(response).to have_http_status(:not_found)

      post "/api/v1/admin/users/#{regular.id}/suspend",  headers: auth_headers(regular), as: :json
      expect(response).to have_http_status(:not_found)

      post "/api/v1/admin/events/#{event.id}/unpublish", headers: auth_headers(regular), as: :json
      expect(response).to have_http_status(:not_found)

      delete "/api/v1/admin/events/#{event.id}",           headers: auth_headers(regular), as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Suspension enforcement across the whole API ──────────────────────────────
  describe "suspension enforcement" do
    it "rejects an already-issued token once the account is suspended" do
      # The important case: JWTs here are stateless and valid for 30 days, so
      # a token minted before the suspension must stop working immediately
      # rather than outliving the suspension by weeks.
      headers = auth_headers(regular)

      get "/api/v1/auth/me", headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      regular.suspend!(reason: "Spam")

      get "/api/v1/auth/me", headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("account_suspended")
    end

    it "blocks a suspended user from creating events" do
      regular.suspend!

      post "/api/v1/events",
           params: { event: { title: "Blocked", category: "running", start_at: 1.week.from_now } },
           headers: auth_headers(regular),
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "still allows a suspended user's account to be read publicly-scoped endpoints without a token" do
      # Suspension gates the account, not the public catalogue.
      regular.suspend!

      get "/api/v1/events", as: :json

      expect(response).to have_http_status(:ok)
    end

    it "lets the user back in after unsuspension" do
      regular.suspend!
      regular.unsuspend!

      get "/api/v1/auth/me", headers: auth_headers(regular), as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  # ── GET /api/v1/admin/users ──────────────────────────────────────────────────
  describe "GET /api/v1/admin/users" do
    it "lists users with moderation-relevant fields and pagination meta" do
      regular.profile.update!(display_name: "Alex Runner")
      create(:event, creator: regular)

      get "/api/v1/admin/users", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      entry = json["users"].find { |u| u["id"] == regular.id }
      expect(entry["email"]).to eq(regular.email)
      expect(entry["display_name"]).to eq("Alex Runner")
      expect(entry["suspended"]).to be(false)
      expect(entry["admin"]).to be(false)
      expect(entry["events_count"]).to eq(1)
      expect(json["meta"]).to include("page" => 1, "per_page" => AdminUserIndexRequestSchema::DEFAULT_PER_PAGE)
    end

    it "searches by email" do
      target = create(:user, email: "findme@example.com")

      get "/api/v1/admin/users", params: { q: "findme" }, headers: auth_headers(admin)

      expect(json["users"].map { |u| u["id"] }).to eq([ target.id ])
    end

    it "searches by profile display name" do
      target = create(:user)
      target.profile.update!(display_name: "Distinctive Name")

      get "/api/v1/admin/users", params: { q: "distinctive" }, headers: auth_headers(admin)

      expect(json["users"].map { |u| u["id"] }).to include(target.id)
    end

    it "filters to suspended accounts" do
      suspended = create(:user)
      suspended.suspend!(reason: "Abuse")

      get "/api/v1/admin/users", params: { status: "suspended" }, headers: auth_headers(admin)

      ids = json["users"].map { |u| u["id"] }
      expect(ids).to eq([ suspended.id ])
      expect(json["users"].first["suspension_reason"]).to eq("Abuse")
    end

    it "filters to active accounts" do
      suspended = create(:user)
      suspended.suspend!

      get "/api/v1/admin/users", params: { status: "active" }, headers: auth_headers(admin)

      expect(json["users"].map { |u| u["id"] }).not_to include(suspended.id)
    end

    it "rejects an unknown status" do
      get "/api/v1/admin/users", params: { status: "banished" }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "paginates" do
      # destroy_all, not delete_all — every user has an auto-created Profile
      # (User#create_profile!), and delete_all is a raw bulk DELETE that
      # skips dependent: :destroy, so it 500s on that FK the moment any
      # leftover user exists.
      User.where.not(id: admin.id).destroy_all
      3.times { create(:user) }

      get "/api/v1/admin/users", params: { per_page: 2 }, headers: auth_headers(admin)

      expect(json["users"].size).to eq(2)
      expect(json["meta"]["total_count"]).to eq(4) # 3 + the admin
      expect(json["meta"]["total_pages"]).to eq(2)
    end
  end

  # ── POST /api/v1/admin/users/:id/suspend ─────────────────────────────────────
  describe "POST /api/v1/admin/users/:id/suspend" do
    it "suspends the user, records the reason, and unpublishes their events" do
      published = create(:event, creator: regular, is_published: true)

      post "/api/v1/admin/users/#{regular.id}/suspend",
           params: { reason: "Fraudulent event listings" },
           headers: auth_headers(admin),
           as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["suspended"]).to be(true)
      expect(json["user"]["suspension_reason"]).to eq("Fraudulent event listings")

      expect(regular.reload).to be_suspended
      # Suspension has to take effect publicly, not just block the account.
      expect(published.reload.is_published).to be(false)
    end

    it "does not touch the suspended user's own registrations for other events" do
      # Cancelling someone's paid registration is a refund decision, not a
      # moderation side effect.
      other_event = create(:event)
      registration = create(:registration, event: other_event, user: regular, payment_status: "paid")

      post "/api/v1/admin/users/#{regular.id}/suspend", headers: auth_headers(admin), as: :json

      expect(Registration.find_by(id: registration.id)).to be_present
      expect(registration.reload.payment_status).to eq("paid")
    end

    it "works without a reason" do
      post "/api/v1/admin/users/#{regular.id}/suspend", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(regular.reload).to be_suspended
      expect(regular.suspension_reason).to be_nil
    end

    it "rejects a reason longer than the maximum" do
      post "/api/v1/admin/users/#{regular.id}/suspend",
           params: { reason: "a" * (AdminSuspendUserRequestSchema::MAX_REASON_LENGTH + 1) },
           headers: auth_headers(admin),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(regular.reload).not_to be_suspended
    end

    it "refuses to let an admin suspend themselves" do
      post "/api/v1/admin/users/#{admin.id}/suspend", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("self_suspend")
      expect(admin.reload).not_to be_suspended
    end

    it "refuses to suspend another admin" do
      other_admin = create(:user, admin: true)

      post "/api/v1/admin/users/#{other_admin.id}/suspend", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("admin_target")
      expect(other_admin.reload).not_to be_suspended
    end

    it "returns 404 for an unknown user" do
      post "/api/v1/admin/users/#{SecureRandom.uuid}/suspend", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── POST /api/v1/admin/users/:id/unsuspend ───────────────────────────────────
  describe "POST /api/v1/admin/users/:id/unsuspend" do
    it "clears the suspension and its reason" do
      regular.suspend!(reason: "Mistake")

      post "/api/v1/admin/users/#{regular.id}/unsuspend", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["user"]["suspended"]).to be(false)
      expect(regular.reload.suspension_reason).to be_nil
    end

    it "does not re-publish events that the suspension took down" do
      # Republishing is the organizer's call — and for a paid plan it has to go
      # back through the plan-payment flow so plan/capacity stay consistent.
      event = create(:event, creator: regular, is_published: true)
      regular.suspend!

      post "/api/v1/admin/users/#{regular.id}/unsuspend", headers: auth_headers(admin), as: :json

      expect(event.reload.is_published).to be(false)
    end
  end

  # ── GET /api/v1/admin/events ─────────────────────────────────────────────────
  describe "GET /api/v1/admin/events" do
    it "includes drafts and past events, unlike the public listing" do
      draft = create(:event, :draft)
      past  = create(:event, :past)

      get "/api/v1/admin/events", headers: auth_headers(admin), as: :json

      ids = json["events"].map { |e| e["id"] }
      expect(ids).to include(draft.id, past.id)
    end

    it "includes the creator and registration count" do
      event = create(:event, creator: regular)
      create(:registration, event: event)

      get "/api/v1/admin/events", headers: auth_headers(admin), as: :json

      entry = json["events"].find { |e| e["id"] == event.id }
      expect(entry["creator"]["id"]).to eq(regular.id)
      expect(entry["creator"]["email"]).to eq(regular.email)
      expect(entry["registrations_count"]).to eq(1)
    end

    it "filters by status" do
      published = create(:event, is_published: true, start_at: 1.week.from_now)
      draft     = create(:event, :draft)

      get "/api/v1/admin/events", params: { status: "draft" }, headers: auth_headers(admin)
      ids = json["events"].map { |e| e["id"] }
      expect(ids).to include(draft.id)
      expect(ids).not_to include(published.id)

      get "/api/v1/admin/events", params: { status: "published" }, headers: auth_headers(admin)
      ids = json["events"].map { |e| e["id"] }
      expect(ids).to include(published.id)
      expect(ids).not_to include(draft.id)
    end

    it "searches by title" do
      target = create(:event, title: "Unmistakable Marathon")

      get "/api/v1/admin/events", params: { q: "unmistakable" }, headers: auth_headers(admin)

      expect(json["events"].map { |e| e["id"] }).to eq([ target.id ])
    end
  end

  # ── POST /api/v1/admin/events/:id/unpublish ──────────────────────────────────
  describe "POST /api/v1/admin/events/:id/unpublish" do
    it "unpublishes without touching registrations or the paid plan" do
      event = create(:event, is_published: true, plan: "small", capacity: 200)
      registration = create(:registration, event: event, payment_status: "paid")

      post "/api/v1/admin/events/#{event.id}/unpublish", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["event"]["is_published"]).to be(false)

      event.reload
      expect(event.is_published).to be(false)
      # Reversible: the plan the organizer paid for survives, so they can
      # republish for free once the issue is resolved.
      expect(event.plan).to eq("small")
      expect(Registration.find_by(id: registration.id)).to be_present
    end

    it "returns 404 for an unknown event" do
      post "/api/v1/admin/events/#{SecureRandom.uuid}/unpublish", headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── DELETE /api/v1/admin/events/:id ──────────────────────────────────────────
  describe "DELETE /api/v1/admin/events/:id" do
    it "requires an explicit confirm flag" do
      event = create(:event)

      expect {
        delete "/api/v1/admin/events/#{event.id}", headers: auth_headers(admin), as: :json
      }.not_to change(Event, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("confirmation_required")
    end

    it "deletes the event when confirmed" do
      event = create(:event)

      expect {
        delete "/api/v1/admin/events/#{event.id}",
               params: { confirm: true },
               headers: auth_headers(admin),
               as: :json
      }.to change(Event, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end

    it "refuses to delete an event that has paid registrations" do
      # Hard-deleting an event with money attached would destroy the payment
      # records needed to actually issue refunds.
      event = create(:event)
      create(:registration, event: event, payment_status: "paid")

      expect {
        delete "/api/v1/admin/events/#{event.id}",
               params: { confirm: true },
               headers: auth_headers(admin),
               as: :json
      }.not_to change(Event, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("has_paid_registrations")
    end

    it "allows deletion when registrations exist but none are paid" do
      event = create(:event)
      create(:registration, event: event, payment_status: "unpaid")

      expect {
        delete "/api/v1/admin/events/#{event.id}",
               params: { confirm: true },
               headers: auth_headers(admin),
               as: :json
      }.to change(Event, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end
  end
end
