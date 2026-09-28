require "rails_helper"

# Assigning staff roles — D10 of docs/staff-roles-design.md.
#
# This endpoint hands out access to the moderation console, so the examples
# that matter are the ones about what it *won't* do. A happy path proves it
# works; the refusals are why it is allowed to exist at all instead of leaving
# everything to a production console.
RSpec.describe "Staff role assignment", type: :request do
  let(:admin)     { create(:user, :admin) }
  let!(:second_admin) { create(:user, :admin) } # so the last-admin guard isn't what's under test
  let(:moderator) { create(:user, :moderator) }
  let(:target)    { create(:user) }

  def grant(role, to:, as: admin, approve: true)
    grant_staff_approval!(:grant_staff_role, to, requester: as, payload: { staff_role: role }) if approve
    post "/api/v1/admin/users/#{to.id}/staff_role",
         params: { staff_role: role }, headers: auth_headers(as), as: :json
  end

  def revoke(from:, as: admin)
    delete "/api/v1/admin/users/#{from.id}/staff_role", headers: auth_headers(as), as: :json
  end

  describe "granting" do
    it "gives an ordinary account a support role" do
      grant("support", to: target)

      expect(response).to have_http_status(:ok)
      expect(target.reload.staff_role).to eq("support")
    end

    it "needs a second signature" do
      grant("moderator", to: target, approve: false)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("approval_required")
      expect(target.reload).not_to be_staff
    end

    # The property the whole decision turns on. Four-eyes defends against one
    # person acting alone; it does nothing about one *session* being stolen,
    # which is why admin is console-only and no approval can change that.
    it "will not grant admin, however well approved" do
      grant("admin", to: target)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("role_not_assignable")
      expect(target.reload).not_to be_admin
    end

    it "will not let an admin change their own role" do
      grant("support", to: admin)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("self_role_change")
      expect(admin.reload).to be_admin
    end

    it "will not touch an existing admin in either direction" do
      grant("support", to: second_admin)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("admin_target")
      expect(second_admin.reload).to be_admin
    end

    it "is closed to a moderator" do
      # :grant_staff_role is admin-only, so this 404s like the rest of the
      # console does for someone without the capability.
      grant("support", to: target, as: moderator)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "revoking" do
    before { target.update!(staff_role: "moderator") }

    # **The point of the revoke/grant split.** If an account is compromised at
    # 2am you strip it now, not when a colleague wakes up. No approval is
    # created here and none is needed.
    it "works with no second signature at all" do
      revoke(from: target)

      expect(response).to have_http_status(:ok)
      expect(target.reload).not_to be_staff
    end

    it "is idempotent for somebody who has no role" do
      revoke(from: create(:user))

      # Not an error: a panicked double-click shouldn't read as a failure when
      # the outcome is already what you wanted.
      expect(response).to have_http_status(:ok)
    end

    it "still refuses self and admin targets" do
      revoke(from: admin)
      expect(json["code"]).to eq("self_role_change")

      revoke(from: second_admin)
      expect(json["code"]).to eq("admin_target")
      expect(second_admin.reload).to be_admin
    end
  end

  describe "the audit trail" do
    it "records both directions with the roles either side" do
      grant("support", to: target)
      entry = AdminAction.where(action: "grant_staff_role").last
      expect(entry.metadata).to include("from_role" => nil, "to_role" => "support")
      expect(entry.metadata["actor_role"]).to eq("admin")

      revoke(from: target)
      entry = AdminAction.where(action: "revoke_staff_role").last
      expect(entry.metadata).to include("from_role" => "support", "to_role" => nil)
    end
  end

  describe "telling the person" do
    it "notifies on grant and on revoke" do
      expect { grant("moderator", to: target) }
        .to change { target.notifications.where(kind: "staff_role_granted").count }.by(1)

      expect { revoke(from: target) }
        .to change { target.notifications.where(kind: "staff_role_revoked").count }.by(1)
    end
  end

  # Guards the console, not the endpoint — which is the whole reason it lives
  # on the model. The endpoint can't demote an admin at all, so a controller
  # check would protect the path that doesn't need it.
  describe "the last admin" do
    it "cannot be demoted" do
      second_admin.destroy! # leave exactly one admin: `admin`

      expect { admin.update!(staff_role: nil) }
        .to raise_error(ActiveRecord::RecordInvalid, /last remaining admin/)
      expect(admin.reload).to be_admin
    end

    it "can be demoted once somebody else holds the role" do
      expect { admin.update!(staff_role: "moderator") }.not_to raise_error
      expect(admin.reload.staff_role).to eq("moderator")
    end

    it "does not block unrelated saves on the last admin" do
      second_admin.destroy!

      expect { admin.update!(suspension_reason: "note to self") }.not_to raise_error
    end
  end

  describe "visibility" do
    it "shows a role in the user list, so an access review is possible" do
      target.update!(staff_role: "moderator")

      # No search filter: the assertion is about what the serializer exposes,
      # and threading it through `?q=` would make a failure ambiguous between
      # "the field is missing" and "the search didn't match".
      get "/api/v1/admin/users", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      row = json["users"].find { |u| u["id"] == target.id }
      expect(row).to be_present, "the target wasn't on the first page of users"
      expect(row["staff_role"]).to eq("moderator")
    end

    it "reports the role back on the grant response too" do
      grant("support", to: target)

      expect(json["user"]["staff_role"]).to eq("support")
    end
  end
end
