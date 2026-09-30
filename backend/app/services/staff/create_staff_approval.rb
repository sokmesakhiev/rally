# frozen_string_literal: true

module Staff
  # Creates a staff approval request. Extracted from
  # StaffApprovalsController#create to keep the controller thin and
  # business logic in a service object.
  #
  # Handles validation of the request, permission checks, and creation
  # of the StaffApproval record with proper error handling.
  class CreateStaffApproval
    Result = Struct.new(:ok?, :approval, :error, :code, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(requester:, action_name:, target_type:, target_id:, payload:, reason:)
      @requester = requester
      @action_name = action_name.to_sym
      @target_type = target_type
      @target_id = target_id
      # Convert to regular hash with string keys (handles both regular hashes and HashWithIndifferentAccess)
      @payload = payload.to_h.transform_keys(&:to_s)
      @reason = reason.to_s
    end

    def call
      # Validate the capability exists
      unless StaffAuthorization::CAPABILITIES.key?(@action_name)
        return Result.new(
          ok?: false,
          error: "Unknown capability.",
          code: "unknown_capability"
        )
      end

      # Check if requester holds the capability they're requesting approval for
      unless staff_permits?(@action_name, @requester)
        return Result.new(
          ok?: false,
          error: "You can't request approval for something you couldn't do yourself.",
          code: "capability_not_held"
        )
      end

      # Check if this action actually requires approval
      unless StaffApproval.required_for?(@action_name, @payload.symbolize_keys)
        return Result.new(
          ok?: false,
          error: "This action doesn't need a second signature.",
          code: "approval_not_required"
        )
      end

      # D10's no-self-promotion rule - prevent self role changes
      if @action_name == :grant_staff_role && @target_id.to_s == @requester.id
        return Result.new(
          ok?: false,
          error: "You can't propose a change to your own staff role.",
          code: "self_role_change"
        )
      end

      # Check if the role is assignable (not admin)
      if @action_name == :grant_staff_role && !Staff::AssignRole.assignable_role?(@payload["staff_role"])
        return Result.new(
          ok?: false,
          error: "Admin is granted from a console, not here. Assignable roles: " \
                 "#{(User::STAFF_ROLES - [User::ADMIN_ROLE]).join(', ')}.",
          code: "role_not_assignable"
        )
      end

      # Create the approval record
      approval = StaffApproval.new(
        requester: @requester,
        action: @action_name,
        target_type: @target_type,
        target_id: @target_id,
        payload: @payload,
        payload_digest: StaffApproval.digest_for(
          action: @action_name,
          target_type: @target_type,
          target_id: @target_id,
          payload: @payload
        ),
        reason: @reason,
        expires_at: StaffApproval::LIFETIME.from_now
      )

      if approval.save
        Result.new(ok?: true, approval: approval)
      else
        Result.new(
          ok?: false,
          error: approval.errors.full_messages.join(", "),
          code: "validation_failed"
        )
      end
    end

    private

    # Check if the user has the required staff capability
    def staff_permits?(capability, user)
      StaffAuthorization.permits?(capability, user)
    end
  end
end
