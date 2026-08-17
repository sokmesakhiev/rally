module Api
  module V1
    module Admin
      # GET /api/v1/admin/admin_actions — the queryable audit trail. See
      # AdminAction and BaseController#log_admin_action, which writes every
      # row this reads. Scoped to admin actions only (unpublish_event,
      # destroy_event, suspend/unsuspend_user, issue_refund when an admin —
      # not the organizer — issues it) — organizer-level actions (an
      # organizer removing their own participant, deleting their own event)
      # aren't logged here, matching today's log_admin_action surface.
      class AdminActionsController < BaseController
        def index
          validate_params_with_schema(AdminActionIndexRequestSchema) do |validated_params|
            page     = validated_params[:page] || 1
            per_page = validated_params[:per_page] || AdminActionIndexRequestSchema::DEFAULT_PER_PAGE

            scope = AdminAction.recent
              .for_action(validated_params[:action_type])
              .for_admin(validated_params[:admin_id])
            scope = scope.where(target_type: validated_params[:target_type]) if validated_params[:target_type].present?

            total = scope.count

            actions = scope
              .includes(:admin)
              .offset((page - 1) * per_page)
              .limit(per_page)

            render json: {
              admin_actions: actions.map { |a| admin_action_json(a) },
              meta: {
                page: page,
                per_page: per_page,
                total_count: total,
                total_pages: total.zero? ? 0 : (total.to_f / per_page).ceil
              }
            }
          end
        end

        private

        def admin_action_json(admin_action)
          {
            id: admin_action.id,
            action: admin_action.action,
            target_type: admin_action.target_type,
            target_id: admin_action.target_id,
            metadata: admin_action.metadata,
            created_at: admin_action.created_at,
            admin: {
              id: admin_action.admin_id,
              email: admin_action.admin.email
            }
          }
        end
      end
    end
  end
end
