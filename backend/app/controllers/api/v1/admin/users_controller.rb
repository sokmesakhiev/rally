module Api
  module V1
    module Admin
      class UsersController < BaseController
        # GET /api/v1/admin/users
        # Supports ?q= (email or display name), ?status=suspended|active,
        # and pagination.
        def index
          validate_params_with_schema(AdminUserIndexRequestSchema) do |validated_params|
            page     = validated_params[:page] || 1
            per_page = validated_params[:per_page] || AdminUserIndexRequestSchema::DEFAULT_PER_PAGE

            scope = User.all
            scope = scope.suspended if validated_params[:status] == "suspended"
            scope = scope.active    if validated_params[:status] == "active"
            scope = apply_search(scope, validated_params[:q])

            total = scope.count

            users = scope
              .includes(:profile)
              .left_joins(:events)
              .select("users.*, COUNT(DISTINCT events.id) AS events_count")
              .group("users.id")
              .order(created_at: :desc)
              .offset((page - 1) * per_page)
              .limit(per_page)

            render json: {
              users: users.map { |u| user_json(u) },
              meta: pagination_meta(page, per_page, total)
            }
          end
        end

        # POST /api/v1/admin/users/:id/suspend
        def suspend
          user = User.find(params[:id])

          # Guards against an admin locking themselves out with a misclick,
          # which for a single-admin deployment would mean losing all
          # moderation access until someone opens a Rails console.
          if user.id == current_user.id
            render json: { error: "You cannot suspend your own account.", code: "self_suspend" },
                   status: :unprocessable_entity
            return
          end

          if user.admin?
            render json: { error: "Admin accounts cannot be suspended.", code: "admin_target" },
                   status: :unprocessable_entity
            return
          end

          validate_params_with_schema(AdminSuspendUserRequestSchema) do |validated_params|
            user.suspend!(reason: validated_params[:reason])
            log_admin_action("suspend_user", user)

            render json: { user: user_json(user.reload) }
          end
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found" }, status: :not_found
        end

        # POST /api/v1/admin/users/:id/unsuspend
        def unsuspend
          user = User.find(params[:id])
          user.unsuspend!
          log_admin_action("unsuspend_user", user)

          render json: { user: user_json(user.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "User not found" }, status: :not_found
        end

        private

        def apply_search(scope, term)
          query = term.to_s.strip
          return scope if query.blank?

          pattern = "%#{User.sanitize_sql_like(query)}%"
          scope
            .left_joins(:profile)
            .where(
              "users.email ILIKE :pattern OR profiles.display_name ILIKE :pattern",
              pattern: pattern
            )
        end

        def pagination_meta(page, per_page, total)
          {
            page: page,
            per_page: per_page,
            total_count: total,
            total_pages: total.zero? ? 0 : (total.to_f / per_page).ceil
          }
        end

        def user_json(user)
          {
            id: user.id,
            email: user.email,
            display_name: user.profile&.display_name,
            email_verified: user.email_verified?,
            admin: user.admin?,
            suspended: user.suspended?,
            suspended_at: user.suspended_at,
            suspension_reason: user.suspension_reason,
            provider: user.provider,
            # Only present on the index query, which selects it — nil elsewhere
            # rather than triggering a per-user COUNT.
            events_count: user.attributes["events_count"],
            created_at: user.created_at
          }
        end
      end
    end
  end
end
