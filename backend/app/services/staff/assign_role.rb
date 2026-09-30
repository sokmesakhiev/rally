# frozen_string_literal: true

module Staff
  # Applies a staff role. **The only path that grants one** — D11 of
  # docs/staff-roles-design.md.
  #
  # Granting happens when a second admin *approves* a `grant_staff_role`
  # request, not through an endpoint of its own. That makes it two steps and
  # one each: propose, approve, done. D9's rule for the other gated actions —
  # "no endpoint performs the approved action, or there would be two
  # implementations that drift" — is respected rather than broken, because
  # there is no second implementation to drift from: this class is it, and
  # the approval flow is its only caller.
  #
  # Revoking is not here. It is immediate, unapproved and lives in
  # Admin::UsersController, because taking access away must never wait on a
  # colleague.
  class AssignRole
    Result = Struct.new(:ok?, :error, :code, keyword_init: true)

    def self.call(...) = new(...).call

    # Shared with StaffApprovalsController#create so a request that could
    # never be approved is refused when it is raised, rather than queued and
    # failed on somebody else's desk. A queue full of requests that cannot
    # succeed is how reviewers learn to approve without reading.
    def self.assignable_role?(role)
      User::STAFF_ROLES.include?(role.to_s) && role.to_s != User::ADMIN_ROLE
    end

    def initialize(user:, role:, actor:, approval: nil)
      @user = user
      @role = role.to_s
      @actor = actor
      @approval = approval
    end

    def call
      # **Re-checked at apply time, not just when the request was raised.**
      # Hours can pass between the two, and every one of these can change in
      # between: the target can be promoted to admin by a console, or turn
      # out to be the approver themselves. An approval authorises a change to
      # a state of the world, and the world is allowed to move.
      problem = refusal
      return problem if problem

      ActiveRecord::Base.transaction do
        previous = @user.staff_role
        @user.update!(staff_role: @role)

        AdminAction.log!(
          admin: @actor, action: "grant_staff_role", target: @user,
          metadata: {
            from_role: previous,
            to_role: @role,
            staff_approval_id: @approval&.id,
            # The approver is the actor — they are the one who made it
            # happen — but who *asked* is half the record, and a two-person
            # control whose log names only one of them is not much of one.
            requested_by_id: @approval&.requester_id
          }
        )
        Notifications::StaffRoleNotifier.granted(@user, role: @role, by: @actor)
        @approval&.consume!
      end

      Result.new(ok?: true)
    rescue ActiveRecord::RecordInvalid => e
      # The last-admin guard lands here, among others.
      Result.new(ok?: false, error: e.record.errors.full_messages.join(", "),
                 code: "role_not_applied")
    end

    private

    def refusal
      unless self.class.assignable_role?(@role)
        return Result.new(ok?: false, code: "role_not_assignable",
                          error: "Admin is granted from a console, not here.")
      end
      # Defence in depth, and currently unreachable through the only caller:
      # the approver must hold `grant_staff_role` (admin-only) and the target
      # must not be an admin, so the two can never be the same person. Kept
      # because that reasoning depends on the capability matrix, and matrices
      # change. Self-proposal is caught earlier, where the actor is the
      # proposer — see StaffApprovalsController#create.
      if @user.id == @actor.id
        return Result.new(ok?: false, code: "self_role_change",
                          error: "You can't change your own staff role.")
      end
      if @user.admin?
        return Result.new(ok?: false, code: "admin_target",
                          error: "An admin's role is managed from a console.")
      end

      nil
    end
  end
end
