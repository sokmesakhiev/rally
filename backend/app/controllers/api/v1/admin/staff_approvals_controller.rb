module Api
  module V1
    module Admin
      # The request/approve queue for four-eyes actions — D9 of
      # docs/staff-roles-design.md.
      #
      # Note what is *not* here: an endpoint that performs the approved
      # action. An approval authorises the requester to go and do the thing
      # themselves through its normal endpoint, where
      # StaffAuthorization#require_second_signature! finds it. Executing from
      # here would mean a second implementation of four irreversible actions,
      # and the two would drift.
      class StaffApprovalsController < BaseController
        ACTION_CAPABILITIES = {
          "index"   => :read_staff_approvals,
          "create"  => :read_staff_approvals,
          "approve" => :read_staff_approvals,
          "reject"  => :read_staff_approvals
        }.freeze

        # `:read_staff_approvals` gets everyone through the door; the real
        # authorization is per-row and lives in the actions below, because it
        # depends on the capability *being requested* rather than on this
        # controller. A support agent may legitimately see the queue and be
        # unable to approve a single thing in it.

        # GET /api/v1/admin/staff_approvals
        def index
          approvals = StaffApproval.includes(:requester, :approver, :target).recent.limit(100)

          render json: {
            staff_approvals: approvals.map { |a| approval_json(a) }
          }
        end

        # POST /api/v1/admin/staff_approvals
        #
        # Asks for a signature. The requester must hold the capability they're
        # asking to exercise — an approval is a second opinion on an action
        # you could otherwise take, not a way to borrow a power you don't have.
        def create
          capability = params[:action_name].to_s.to_sym

          unless StaffAuthorization::CAPABILITIES.key?(capability)
            return render json: { error: "Unknown capability.", code: "unknown_capability" },
                          status: :unprocessable_entity
          end

          unless staff_permits?(capability)
            return render json: {
              error: "You can't request approval for something you couldn't do yourself.",
              code: "capability_not_held"
            }, status: :forbidden
          end

          payload = (params[:payload] || {}).to_unsafe_h.transform_keys(&:to_s)

          unless StaffApproval.required_for?(capability, payload.symbolize_keys)
            # Refusing rather than creating a no-op approval: a queue full of
            # signatures nothing will ever consume trains reviewers to approve
            # without reading.
            return render json: {
              error: "This action doesn't need a second signature.",
              code: "approval_not_required"
            }, status: :unprocessable_entity
          end

          approval = StaffApproval.new(
            requester: current_user,
            action: capability,
            target_type: params[:target_type],
            target_id: params[:target_id],
            payload: payload,
            payload_digest: StaffApproval.digest_for(
              action: capability,
              target_type: params[:target_type],
              target_id: params[:target_id],
              payload: payload
            ),
            reason: params[:reason].to_s,
            expires_at: StaffApproval::LIFETIME.from_now
          )

          if approval.save
            render json: { staff_approval: approval_json(approval) }, status: :created
          else
            render json: { error: approval.errors.full_messages.join(", ") },
                   status: :unprocessable_entity
          end
        end

        # POST /api/v1/admin/staff_approvals/:id/approve
        def approve
          approval = StaffApproval.find(params[:id])
          return unless approvable!(approval)

          approval.approve!(current_user)
          log_admin_action("approve_staff_action", approval)

          render json: { staff_approval: approval_json(approval.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Approval not found" }, status: :not_found
        end

        # POST /api/v1/admin/staff_approvals/:id/reject
        #
        # Same gate as approving: saying no is as much a decision as saying
        # yes, and someone who can't judge the action can't judge it either way.
        def reject
          approval = StaffApproval.find(params[:id])
          return unless approvable!(approval)

          approval.reject!(current_user)
          log_admin_action("reject_staff_action", approval)

          render json: { staff_approval: approval_json(approval.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Approval not found" }, status: :not_found
        end

        private

        # The three things that make a second signature mean anything.
        def approvable!(approval)
          if approval.requester_id == current_user.id
            # The whole mechanism, in one clause. Self-approval is one person
            # with extra steps.
            render json: { error: "You can't approve your own request.", code: "self_approval" },
                   status: :forbidden
            return false
          end

          unless staff_permits?(approval.action.to_sym)
            # A signature from somebody who couldn't perform the action is a
            # rubber stamp — they have no standing to judge it.
            render json: {
              error: "You don't hold the capability this request needs.",
              code: "capability_not_held"
            }, status: :forbidden
            return false
          end

          unless approval.status == "pending" && !approval.expired?
            render json: {
              error: "This request is no longer open.",
              code: "approval_not_open"
            }, status: :unprocessable_entity
            return false
          end

          true
        end

        def approval_json(approval)
          {
            id: approval.id,
            action: approval.action,
            target_type: approval.target_type,
            target_id: approval.target_id,
            payload: approval.payload,
            reason: approval.reason,
            status: approval.status,
            # Evaluated, not stored — see the model. A client showing a stale
            # "pending" on something that timed out an hour ago would invite
            # somebody to approve it and then wonder why it didn't work.
            expired: approval.expired?,
            expires_at: approval.expires_at,
            approved_at: approval.approved_at,
            consumed_at: approval.consumed_at,
            requester: { id: approval.requester_id, email: approval.requester.email },
            approver: approval.approver && {
              id: approval.approver_id, email: approval.approver.email
            },
            created_at: approval.created_at
          }
        end
      end
    end
  end
end
