# frozen_string_literal: true

# Four-eyes approval for the handful of staff actions that are irreversible or
# spend money — D9 of docs/staff-roles-design.md, Phase 4.
#
# One staff member requests, a *different* one who also holds the capability
# approves, and only then does the action execute. Deliberately narrow: three
# actions plus refunds above a threshold. A control that makes routine work
# painful gets routed around, usually by giving everybody the top role, which
# is the exact failure the role split exists to prevent.
class CreateStaffApprovals < ActiveRecord::Migration[8.1]
  def change
    create_table :staff_approvals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # Who asked. Not nullable and not nullified on delete: an approval is a
      # record of a decision two people made, and "somebody requested this"
      # with nobody named is not that record. Staff accounts are soft-deleted
      # (User#discard!) rather than destroyed, so the row survives an
      # offboarding.
      t.references :requester, null: false, foreign_key: { to_table: :users }, type: :uuid
      # Null until somebody acts on it.
      t.references :approver, foreign_key: { to_table: :users }, type: :uuid, null: true

      # The capability being requested — `delete_event`, `waive_plan_payment`,
      # and so on. A capability name rather than a controller action, because
      # the gate that consumes this is StaffAuthorization#require_staff!, which
      # thinks in capabilities.
      t.string :action, null: false
      t.references :target, polymorphic: true, null: false, type: :uuid

      # The parameters this approval authorises, and their digest.
      #
      # **The digest is the point.** An approval authorises *this refund of
      # $240 on this payment*, not "a refund". Without pinning, an approved
      # request could be edited into a different one between approval and
      # execution — which is the whole mechanism defeated by a query-string
      # change. `payload` is kept alongside for the reviewer to read; the
      # digest is what the gate compares.
      t.jsonb :payload, null: false, default: {}
      t.string :payload_digest, null: false

      # Why. Shown to the approver, who otherwise has nothing to decide on.
      t.text :reason, null: false

      # pending → approved → consumed, or → rejected. Expiry is evaluated from
      # `expires_at` rather than stored as a state — a status column that needs
      # a cron job to stay truthful has a window where it lies, which is the
      # house rule (see Event#registration_closed?, ImpersonationSession#live?).
      t.string :status, null: false, default: "pending"
      t.datetime :expires_at, null: false
      t.datetime :approved_at
      t.datetime :consumed_at

      t.timestamps
    end

    # The queue: what is waiting on somebody, oldest first.
    add_index :staff_approvals, [ :status, :created_at ]
    # The gate's lookup — find a usable approval for this requester and action.
    add_index :staff_approvals, [ :requester_id, :action, :status ]
  end
end
