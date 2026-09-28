require "rails_helper"

# What the two new roles can and cannot reach (Phase 2 of
# docs/staff-roles-design.md).
#
# `spec/requests/admin_capability_coverage_spec.rb` proves every admin action
# *has* a capability; this proves the capabilities mean something. The pairing
# matters: coverage without enforcement is a matrix nobody obeys, enforcement
# without coverage is a matrix with holes.
#
# Endpoints are hit for real rather than asserting on the matrix, because the
# matrix asserting about itself would pass however the controllers were wired.
RSpec.describe "Staff roles", type: :request do
  let(:support)   { create(:user, staff_role: "support") }
  let(:moderator) { create(:user, staff_role: "moderator") }
  let(:admin)     { create(:user, staff_role: "admin") }
  let(:nobody)    { create(:user) }

  # 404 rather than 403 throughout: a staff surface shouldn't confirm its own
  # existence to someone who can't use it. Same call as the old require_admin!.
  def expect_refused
    expect(response).to have_http_status(:not_found)
  end

  describe "support" do
    it "reaches the support inbox — the job the role exists for" do
      get "/api/v1/admin/conversations", headers: auth_headers(support), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "reaches the user list, for ticket context" do
      get "/api/v1/admin/users", headers: auth_headers(support), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "cannot read the report queue" do
      get "/api/v1/admin/event_reports", headers: auth_headers(support), as: :json

      expect_refused
    end

    it "cannot suspend a user" do
      target = create(:user)

      post "/api/v1/admin/users/#{target.id}/suspend",
           params: { reason: "Because I can" }, headers: auth_headers(support), as: :json

      expect_refused
      expect(target.reload).not_to be_suspended
    end

    it "cannot read the audit log that would show what it did" do
      get "/api/v1/admin/admin_actions", headers: auth_headers(support), as: :json

      expect_refused
    end
  end

  describe "moderator" do
    it "reaches the report queue" do
      get "/api/v1/admin/event_reports", headers: auth_headers(moderator), as: :json

      expect(response).to have_http_status(:ok)
    end

    it "can suspend an event — the reversible, protective action" do
      event = create(:event)

      post "/api/v1/admin/events/#{event.id}/suspend",
           params: { reason: "Reported as a gambling event" },
           headers: auth_headers(moderator), as: :json

      expect(response).to have_http_status(:ok)
      expect(event.reload).to be_suspended
    end

    it "cannot delete an event — irreversible, and destroys registrations" do
      event = create(:event)

      # `confirm: true` deliberately included. Admin::EventsController#destroy
      # refuses an unconfirmed delete with 422 *after* the before_action runs,
      # so omitting it would leave this example unable to tell "the capability
      # refused you" from "you forgot to confirm" — and it would keep passing
      # if the capability check were removed.
      delete "/api/v1/admin/events/#{event.id}",
             params: { confirm: true }, headers: auth_headers(moderator), as: :json

      expect_refused
      expect(event.reload).not_to be_discarded
    end

    it "cannot read the audit log" do
      get "/api/v1/admin/admin_actions", headers: auth_headers(moderator), as: :json

      expect_refused
    end
  end

  describe "admin" do
    # Phase 1's contract, exercised end to end rather than by reading the
    # matrix: the three endpoints the lesser roles were refused above.
    it "reaches everything the lesser roles were refused" do
      get "/api/v1/admin/event_reports", headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:ok)

      get "/api/v1/admin/admin_actions", headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:ok)

      # Deletion carries *three* gates now, and they stack rather than
      # replace: the capability, a `confirm=true` one-person "are you sure",
      # and a second person's signature (D9). All three have to be satisfied
      # for this to be a test of the capability rather than of whichever gate
      # happens to fail first.
      event = create(:event)
      grant_staff_approval!(:delete_event, event, requester: admin)
      delete "/api/v1/admin/events/#{event.id}",
             params: { confirm: true }, headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:ok)
      expect(event.reload).to be_discarded
    end
  end

  describe "everyone else" do
    it "gets 404 from the console, as before" do
      get "/api/v1/admin/conversations", headers: auth_headers(nobody), as: :json

      expect_refused
    end

    it "gets 401 with no token at all" do
      get "/api/v1/admin/conversations", as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "the payload the console reads" do
    it "carries the role, so the client can pick which tabs to render" do
      get "/api/v1/auth/me", headers: auth_headers(moderator), as: :json

      expect(json["user"]["staff_role"]).to eq("moderator")
      # `admin` stays alongside it until Phase 3 drops the column — a deployed
      # frontend outlives a backend deploy.
      expect(json["user"]["admin"]).to be(false)
    end

    it "sends null for the overwhelming majority who aren't staff" do
      get "/api/v1/auth/me", headers: auth_headers(nobody), as: :json

      expect(json["user"]["staff_role"]).to be_nil
    end
  end
end
