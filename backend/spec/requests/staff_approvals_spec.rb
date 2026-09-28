require "rails_helper"

# Four-eyes approval — D9 of docs/staff-roles-design.md.
#
# The examples worth reading are the refusals. A happy path proves the feature
# runs; the refusals are the feature. Each of the six properties D9 lists is a
# way the mechanism is defeated if it's missing, so each gets an example named
# after the attack rather than after the code.
RSpec.describe "Staff approvals", type: :request do
  let(:admin)     { create(:user, :admin) }
  let(:other)     { create(:user, :admin) }
  let(:moderator) { create(:user, :moderator) }
  let!(:event)    { create(:event) }

  def request_approval(as:, capability: "delete_event", target: event, payload: {})
    post "/api/v1/admin/staff_approvals",
         params: {
           action_name: capability,
           target_type: target.class.name,
           target_id: target.id,
           payload: payload,
           reason: "Duplicate listing, organizer asked us to remove it"
         },
         headers: auth_headers(as), as: :json
    json["staff_approval"]
  end

  def approve(id, as:)
    post "/api/v1/admin/staff_approvals/#{id}/approve", headers: auth_headers(as), as: :json
  end

  def delete_the_event(as:)
    delete "/api/v1/admin/events/#{event.id}",
           params: { confirm: true }, headers: auth_headers(as), as: :json
  end

  describe "the gate" do
    it "refuses a gated action with no approval, and says why" do
      delete_the_event(as: admin)

      # 403 with a code, not the console's usual 404: the caller *is* staff and
      # *does* hold the capability. Pretending the endpoint doesn't exist would
      # be a lie, and the client needs to tell "you can't" from "not yet".
      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("approval_required")
      expect(event.reload).not_to be_discarded
    end

    it "lets the action through once a colleague has signed it" do
      approval = request_approval(as: admin)
      approve(approval["id"], as: other)

      delete_the_event(as: admin)

      expect(response).to have_http_status(:ok)
      expect(event.reload).to be_discarded
    end

    it "lets a missing target 404 instead of demanding approval for it" do
      # The gate must not stand in front of a record that isn't there. Telling
      # an admin to fetch a signature for a nonexistent event is a dead end —
      # StaffApproval#target is a `belongs_to`, so the approval they were sent
      # to get cannot be created. It hides nothing either: anyone holding this
      # capability can already list every event from the console.
      delete "/api/v1/admin/events/#{SecureRandom.uuid}",
             params: { confirm: true }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end

    # No example for a malformed (non-UUID) id, deliberately.
    # `Admin::EventsController#destroy` does `Event.find(params[:id])` and
    # rescues only RecordNotFound, so Postgres' "invalid input syntax for type
    # uuid" surfaces as a 500 — and it did so long before four-eyes existed.
    # The gate itself is safe (four_eyes_target_exists? rescues
    # StatementInvalid rather than becoming the thing that raises), but
    # asserting 404 here would pin behaviour the app doesn't have, and
    # asserting 500 would pin a bug as correct. Fixing it belongs with the
    # controllers, not with this feature.

    it "leaves ungated actions alone" do
      # The control. If four-eyes leaked into everything, the examples above
      # would still pass and the console would be unusable.
      post "/api/v1/admin/events/#{event.id}/suspend",
           params: { reason: "Reported for gambling" }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the refusals that make it mean something" do
    it "will not let the requester approve their own request" do
      approval = request_approval(as: admin)

      approve(approval["id"], as: admin)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("self_approval")
    end

    it "will not take a signature from somebody who lacks the capability" do
      approval = request_approval(as: admin)

      # A moderator can't delete events, so their signature on a deletion is a
      # rubber stamp — they have no standing to judge it.
      approve(approval["id"], as: moderator)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("capability_not_held")
    end

    it "will not let an approval be spent twice" do
      approval = request_approval(as: admin)
      approve(approval["id"], as: other)

      delete_the_event(as: admin)
      expect(response).to have_http_status(:ok)

      second = create(:event)
      delete "/api/v1/admin/events/#{second.id}",
             params: { confirm: true }, headers: auth_headers(admin), as: :json

      # Pinned to *that* event as well as consumed, so this fails twice over.
      expect(response).to have_http_status(:forbidden)
      expect(second.reload).not_to be_discarded
      expect(StaffApproval.find(approval["id"]).status).to eq("consumed")
    end

    it "will not honour an expired approval" do
      approval = request_approval(as: admin)
      approve(approval["id"], as: other)
      StaffApproval.find(approval["id"])
        .update_column(:expires_at, StaffApproval::LIFETIME.from_now - 1.day - 1.minute)

      delete_the_event(as: admin)

      expect(response).to have_http_status(:forbidden)
      expect(event.reload).not_to be_discarded
    end

    it "will not let a colleague spend somebody else's approval" do
      approval = request_approval(as: admin)
      approve(approval["id"], as: other)

      # `other` approved it; that does not make it theirs to use. Without the
      # requester check an approval is a bearer token any colleague can spend.
      delete_the_event(as: other)

      expect(response).to have_http_status(:forbidden)
      expect(event.reload).not_to be_discarded
    end
  end

  # The property most easily lost in a refactor, and the most expensive: an
  # approval authorises *these parameters*, not this capability in general.
  describe "payload pinning" do
    let(:registration) { create(:registration, event: event) }
    # `:approved` rather than `status: "approved"` — the trait also stamps
    # paid_at, and Refunds::IssueRefund refuses a payment that was never paid.
    let!(:payment) do
      create(:payment, :approved, registration: registration, amount_cents: 24_000)
    end

    def refund(amount_cents, as:)
      post "/api/v1/payments/#{payment.id}/refunds",
           params: { refund: { amount_cents: amount_cents, refund_method: "manual",
                               reason: "Event cancelled" } },
           headers: auth_headers(as), as: :json
    end

    it "does not let an approved amount be edited upward before it is spent" do
      approval = request_approval(
        as: admin, capability: "issue_refund", target: payment,
        payload: { amount_cents: 12_000 }
      )
      approve(approval["id"], as: other)

      refund(24_000, as: admin)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("approval_required")
      expect(payment.reload.refunded_amount_cents).to eq(0)
    end

    it "honours the amount that was actually approved" do
      approval = request_approval(
        as: admin, capability: "issue_refund", target: payment,
        payload: { amount_cents: 12_000 }
      )
      approve(approval["id"], as: other)

      refund(12_000, as: admin)

      expect(response).to have_http_status(:created)
    end

    it "leaves small refunds ungated" do
      # Below FOUR_EYES_REFUND_CENTS. A second signature on every routine
      # refund is the bottleneck that gets solved by handing everyone the
      # admin role — the exact failure the role split exists to prevent.
      refund(StaffApproval::FOUR_EYES_REFUND_CENTS - 1, as: admin)

      expect(response).to have_http_status(:created)
    end
  end

  describe "requesting" do
    it "refuses to open a request for a capability the requester lacks" do
      request_approval(as: moderator)

      expect(response).to have_http_status(:forbidden)
      expect(json["code"]).to eq("capability_not_held")
    end

    it "refuses to open a request for something that needs no signature" do
      request_approval(as: admin, capability: "suspend_event")

      # A queue full of signatures nothing will consume trains reviewers to
      # approve without reading.
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["code"]).to eq("approval_not_required")
    end
  end

  describe "the audit trail" do
    it "links the action to the approval that authorised it" do
      approval = request_approval(as: admin)
      approve(approval["id"], as: other)
      delete_the_event(as: admin)

      entry = AdminAction.where(action: "destroy_event").last
      expect(entry.metadata["staff_approval_id"]).to eq(approval["id"])
      # The approval records intent, the AdminAction records that it happened.
      # Both, linked — losing either loses the difference between asked and did.
      expect(entry.metadata["actor_role"]).to eq("admin")
    end
  end
end
