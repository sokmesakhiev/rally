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

  # Two steps, one each — D11. There is no grant endpoint: proposing creates a
  # StaffApproval, and a *different* admin approving it is what applies the
  # role. `propose` and `sign` mirror the two halves so the examples below
  # read as the flow does.
  def propose(role, to:, as: admin)
    post "/api/v1/admin/staff_approvals",
         params: {
           action_name: "grant_staff_role",
           target_type: "User", target_id: to.id,
           payload: { staff_role: role },
           reason: "Joining the support rota next week"
         },
         headers: auth_headers(as), as: :json
    json["staff_approval"]
  end

  def sign(approval, as: second_admin)
    post "/api/v1/admin/staff_approvals/#{approval['id']}/approve",
         headers: auth_headers(as), as: :json
  end

  # The whole happy path, for examples whose subject is somewhere else.
  def grant(role, to:, as: admin, signer: second_admin)
    sign(propose(role, to: to, as: as), as: signer)
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

    it "does nothing until somebody signs it" do
      propose("moderator", to: target)

      expect(response).to have_http_status(:created)
      # Proposing is not granting. The role only moves at approval.
      expect(target.reload).not_to be_staff
    end

    # The whole mechanism in one example: the proposer's own signature is not
    # a second signature.
    it "will not let the proposer approve their own request" do
      approval = propose("support", to: target)

      sign(approval, as: admin)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("self_approval")
      expect(target.reload).not_to be_staff
    end

    # The property the whole decision turns on. Four-eyes defends against one
    # person acting alone; it does nothing about one *session* being stolen,
    # which is why admin is console-only and no approval can change that.
    it "will not let anyone propose admin" do
      propose("admin", to: target)

      # Refused when raised rather than queued and failed on a reviewer's
      # desk — a queue of requests that cannot succeed is how reviewers learn
      # to approve without reading.
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("role_not_assignable")
      expect(StaffApproval.count).to eq(0)
    end

    it "will not let an admin propose a change to their own role" do
      # Refused at proposal, not at approval. This is the only moment the
      # actor is the proposer, so it's the only moment the answer can be
      # "because you asked for yourself" rather than the technically-true but
      # unhelpful "that target is an admin".
      propose("support", to: admin)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("self_role_change")
      expect(StaffApproval.count).to eq(0)
      expect(admin.reload).to be_admin
    end

    it "will not touch an existing admin" do
      # `second_admin` is the signer everywhere else, so use a third party
      # here to keep the refusal about the *target* rather than the signer.
      victim = create(:user, :admin)

      grant("support", to: victim)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("admin_target")
      expect(victim.reload).to be_admin
    end

    # State can move between proposing and signing, so the checks run again
    # at apply time rather than being trusted from when the request was made.
    it "re-checks at approval, not just when proposed" do
      approval = propose("support", to: target)
      target.update!(staff_role: "admin") # promoted by console in the meantime

      sign(approval)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("admin_target")
    end

    it "is closed to a moderator" do
      # 403, not the console's usual 404. A moderator legitimately reaches the
      # approvals queue — `read_staff_approvals` covers all three roles — so
      # pretending the endpoint isn't there would be a lie. What they lack is
      # `grant_staff_role`, and the response says exactly that. Same
      # distinction the four-eyes gate draws: 404 hides a surface from
      # non-staff, 403 tells staff they need something more.
      propose("support", to: target, as: moderator)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("capability_not_held")
      expect(StaffApproval.count).to eq(0)
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
      # Both halves of a two-person control belong in the record. The actor is
      # the approver, because they are the one who made it happen; the
      # proposer is named alongside rather than lost.
      expect(entry.admin_id).to eq(second_admin.id)
      expect(entry.metadata["requested_by_id"]).to eq(admin.id)

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

    it "leaves the approval consumed once the role is applied" do
      approval = propose("support", to: target)
      sign(approval)

      expect(StaffApproval.find(approval["id"]).status).to eq("consumed")
      expect(target.reload.staff_role).to eq("support")
    end
  end
end
