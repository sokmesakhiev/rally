# frozen_string_literal: true

# A second signature, for the staff actions that are irreversible or spend
# money. D9 of docs/staff-roles-design.md.
#
# The flow: a staff member holding the capability requests one, a *different*
# staff member who also holds it approves, and the original requester then
# performs the action — at which point the approval is consumed and cannot be
# used again.
#
# ── What is gated, and what deliberately isn't ──────────────────────────────
#
# Destruction and money. **Suspending an event is excluded on purpose**: it is
# the protective action, it is how something harmful comes down, and it is
# reversible. A second signature in front of it means harmful content stays up
# until somebody else is awake. Four-eyes belongs on destruction and money,
# never on the brake pedal.
class StaffApproval < ApplicationRecord
  belongs_to :requester, class_name: "User"
  belongs_to :approver, class_name: "User", optional: true
  belongs_to :target, polymorphic: true

  STATUSES = %w[pending approved rejected consumed].freeze

  # Short on purpose. A pending "delete this event" sitting in a queue for a
  # fortnight is a landmine somebody eventually steps on — and an approval
  # granted on Monday's understanding shouldn't still authorise Friday's
  # action.
  LIFETIME = 24.hours

  # Refunds are capped at one registration's fee (Payment#remaining_refundable_cents
  # can't exceed the payment, and a payment is one registration's
  # `owed_amount_cents`), so this only fires on unusually expensive events.
  # That is the intent: quiet day-to-day, present for the one that isn't.
  FOUR_EYES_REFUND_CENTS = 10_000

  # Capabilities that cannot be exercised on one person's say-so.
  #
  # `issue_refund` is conditional rather than listed here — see .required_for?.
  # `grant_staff_role` is here and `revoke_staff_role` deliberately is not —
  # the control belongs on the direction that adds power, never on the
  # recovery. See D10, and `unsuspend_organization` for the same rule learned
  # the expensive way.
  ALWAYS_FOUR_EYES = %i[
    delete_event
    suspend_organization
    waive_plan_payment
    grant_staff_role
  ].freeze

  validates :action, presence: true
  validates :reason, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :payload_digest, presence: true

  scope :pending,  -> { where(status: "pending") }
  scope :recent,   -> { order(created_at: :desc) }
  # Evaluated, never stored — the house rule. A status column meaning
  # "expired" would need a job to maintain and would be wrong in the window
  # before it ran.
  scope :live,     -> { where("expires_at > ?", Time.current) }
  scope :awaiting, -> { pending.live }

  # Whether this capability needs a second signature for these parameters.
  #
  # One method, so the gate and the request endpoint cannot disagree about
  # what is gated. A refund is judged on its amount; everything else on the
  # capability alone.
  def self.required_for?(capability, payload = {})
    return true if ALWAYS_FOUR_EYES.include?(capability)
    return false unless capability == :issue_refund

    payload.to_h.symbolize_keys[:amount_cents].to_i >= FOUR_EYES_REFUND_CENTS
  end

  # A stable fingerprint of what is being authorised.
  #
  # Sorted and JSON-encoded so that key order and symbol-vs-string can't
  # change the digest — the request arrives as JSON and the gate reads params,
  # and those two produce differently-shaped hashes for the same intent.
  def self.digest_for(action:, target_type:, target_id:, payload: {})
    canonical = {
      action: action.to_s,
      target_type: target_type.to_s,
      target_id: target_id.to_s,
      payload: payload.to_h.transform_keys(&:to_s).sort.to_h
    }
    Digest::SHA256.hexdigest(canonical.to_json)
  end

  def expired?(now = Time.current) = expires_at <= now

  # Usable *right now* by this person for these parameters.
  #
  # Every clause is a way the mechanism is defeated if it's missing:
  #   - approved, not pending/rejected — the whole point
  #   - not consumed — single use, so an approval can't be replayed
  #   - not expired — a stale approval is not a current decision
  #   - same requester — otherwise it's a bearer token any colleague can spend
  #   - matching digest — otherwise the parameters can be edited after approval
  def usable_by?(user, digest, now = Time.current)
    status == "approved" &&
      consumed_at.nil? &&
      !expired?(now) &&
      requester_id == user&.id &&
      payload_digest == digest
  end

  def approve!(approver)
    update!(status: "approved", approver: approver, approved_at: Time.current)
  end

  def reject!(approver)
    update!(status: "rejected", approver: approver)
  end

  # Marked the moment the action succeeds. Row-locked, and re-checks that it
  # is still unconsumed inside the lock: two requests racing with the same
  # approval must not both go through, which for `delete_event` is the
  # difference between one audit trail and two.
  def consume!
    with_lock do
      return false unless status == "approved" && consumed_at.nil?

      update!(status: "consumed", consumed_at: Time.current)
      true
    end
  end
end
