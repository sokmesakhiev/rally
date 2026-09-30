# frozen_string_literal: true

# Validates POST /api/v1/admin/staff_approvals.
#
# Every field here reaches something that will misbehave on bad input rather
# than merely reject it, which is why the constraints are tighter than the
# usual "it's a string" pass:
#
#   * `target_type` and `target_id` become a **polymorphic association**.
#     `StaffApproval#target` calls `constantize` on the type and queries with
#     the id, so an unrecognised type raises `NameError` and a non-UUID id
#     raises `PG::InvalidTextRepresentation` — both of which surface as a 500
#     rather than a 422. Constraining them here is what keeps a typo'd request
#     an error message instead of an exception.
#   * `reason` is what the approver reads in order to decide. `StaffApproval`
#     validates its presence, so leaving it optional here only moves the
#     failure to `approval.save`, where it comes back as a generic
#     "validation_failed" instead of naming the field.
class AdminStaffApprovalCreateRequestSchema < ApplicationRequestSchema
  MAX_REASON_LENGTH = 500

  # Canonical 8-4-4-4-12. Every id in this schema addresses a `uuid` column,
  # and Postgres raises on a malformed one rather than simply not matching.
  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # What a four-eyes action can point at — see StaffAuthorization's
  # #four_eyes_target and StaffApproval::ALWAYS_FOUR_EYES. A closed list
  # rather than "any model name", because this value is `constantize`d:
  # user input should never choose which class gets loaded.
  TARGET_TYPES = %w[Event Organization Payment User].freeze

  params do
    # The capability being requested. Constrained to real capability names,
    # in the same spirit as EventRequestSchema pinning `visibility` to
    # Event::VISIBILITIES. Whether that capability *needs* a signature is a
    # different question, and Staff::CreateStaffApproval answers it —
    # `issue_refund` is requestable only above a threshold, which a schema
    # can't see.
    required(:action_name).filled(
      :string, included_in?: StaffAuthorization::CAPABILITIES.keys.map(&:to_s)
    )

    required(:target_type).filled(:string, included_in?: TARGET_TYPES)
    required(:target_id).filled(:string, format?: UUID_FORMAT)

    # Free-form by necessity: the shape differs per capability (`staff_role`
    # for a grant, `amount_cents` for a refund), and it is the *digest* of
    # this that pins what was authorised. `maybe`, because the frontend sends
    # an explicit null for "no extra parameters".
    optional(:payload).maybe(:hash)

    # Required, not optional. An approver with no reason to read is being
    # asked to rubber-stamp.
    required(:reason).filled(:string, max_size?: MAX_REASON_LENGTH)
  end
end
