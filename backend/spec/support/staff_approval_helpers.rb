# frozen_string_literal: true

# Grants a four-eyes approval directly, for the specs whose subject is the
# gated action rather than the approval flow.
#
# Deliberately skips the HTTP request/approve round trip. That path has its own
# coverage in spec/requests/staff_approvals_spec.rb, where the refusals —
# self-approval, payload tampering, replay, expiry — are the point. Repeating
# it in every spec that happens to delete an event would bury what those specs
# are actually testing under four lines of ceremony, and a spec whose setup is
# longer than its assertion stops being read.
#
# `payload` must match what StaffAuthorization#four_eyes_payload derives for
# the capability, since the digest is what the gate compares. Empty for the
# actions whose only variable is their target.
module StaffApprovalHelpers
  def grant_staff_approval!(capability, target, requester:, payload: {}, approver: nil)
    # A second person by default, because that is the one thing an approval
    # cannot be without. Specs that care who signed can pass their own.
    approver ||= create(:user, staff_role: requester.staff_role)

    StaffApproval.create!(
      requester: requester,
      approver: approver,
      action: capability.to_s,
      target: target,
      payload: payload.transform_keys(&:to_s),
      payload_digest: StaffApproval.digest_for(
        action: capability,
        target_type: target.class.name,
        target_id: target.id,
        payload: payload
      ),
      reason: "Approved in a spec",
      status: "approved",
      approved_at: Time.current,
      expires_at: StaffApproval::LIFETIME.from_now
    )
  end
end
