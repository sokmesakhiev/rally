require "rails_helper"

# D8 of docs/staff-roles-design.md: the audit log records what role the actor
# held *at the time*, and never recomputes it.
#
# The property worth protecting is the second half. Reading the role at
# display time would mean a support agent later promoted to admin appears to
# have always been one — and an audit trail that reads differently after a
# promotion is not an audit trail. Same reasoning as `Message#sender_role`,
# which is snapshotted from position in the thread rather than from the
# account's current status, for exactly this reason.
RSpec.describe "AdminAction actor role", type: :model do
  let(:event) { create(:event) }

  it "records the role the actor held" do
    moderator = create(:user, staff_role: "moderator")

    action = AdminAction.log!(admin: moderator, action: "suspend_event", target: event)

    expect(action.metadata["actor_role"]).to eq("moderator")
  end

  # The one that matters.
  it "does not relabel history when the actor is promoted" do
    agent = create(:user, staff_role: "support")
    action = AdminAction.log!(admin: agent, action: "resolve_conversation", target: event)

    agent.update!(staff_role: "admin")

    expect(action.reload.metadata["actor_role"]).to eq("support")
    # …and the association still resolves to the same person, who is now an
    # admin. Both facts are true; the log holds the one that was true then.
    expect(action.admin.reload.staff_role).to eq("admin")
  end

  it "keeps any metadata the caller passed, rather than replacing it" do
    admin = create(:user, staff_role: "admin")

    action = AdminAction.log!(
      admin: admin, action: "issue_refund", target: event,
      metadata: { amount_cents: 2_500 }
    )

    expect(action.metadata).to include("amount_cents" => 2_500, "actor_role" => "admin")
  end

  # Every existing call site omits `metadata:`; none should have had to change.
  it "defaults metadata so existing callers keep working" do
    admin = create(:user, staff_role: "admin")

    expect { AdminAction.log!(admin: admin, action: "verify_user", target: event) }
      .to change(AdminAction, :count).by(1)
  end
end
