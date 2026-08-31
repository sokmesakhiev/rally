module Api
  module V1
    module Admin
      # Staff moderation of organizations — see
      # organization-identity-tickets.md's Ticket J (#339).
      #
      # Suspending an organization takes down every event it presents, because
      # Event#suspended? derives from it. Nothing is written to those events,
      # so unsuspending restores exactly what the cascade took down while any
      # event suspended on its own merits stays down.
      #
      # Shaped to match Admin::EventsController's suspend/unsuspend and
      # Admin::UsersController's, since it's the same concept one level up.
      class OrganizationsController < BaseController
        # GET /api/v1/admin/organizations
        MAX_RESULTS = 100

        def index
          scope = ::Organization.kept

          case params[:status]
          when "suspended" then scope = scope.where.not(suspended_at: nil)
          when "active"    then scope = scope.where(suspended_at: nil)
          when "verified"  then scope = scope.verified
          end

          if params[:q].present?
            # sanitize_sql_like so a literal % or _ in the query is matched as
            # itself rather than as a wildcard — same treatment Event.search
            # gives its term.
            pattern = "%#{::Organization.sanitize_sql_like(params[:q].to_s.strip)}%"
            scope = scope.where(
              "organizations.name ILIKE :pattern OR organizations.slug ILIKE :pattern",
              pattern: pattern
            )
          end

          # includes(:owner) last, and never combined with a raw-SQL condition
          # while building: organization_json reads owner.email, and users also
          # has a suspended_at column, so letting Rails turn this into an
          # eager_load alongside the filters above invites an ambiguous-column
          # error on the status filter.
          organizations = scope.includes(:owner).order(created_at: :desc).limit(MAX_RESULTS)

          render json: { organizations: organizations.map { |o| organization_json(o) } }
        end

        # POST /api/v1/admin/organizations/:id/suspend
        def suspend
          organization = ::Organization.kept.find(params[:id])

          validate_params_with_schema(AdminSuspendOrganizationRequestSchema) do |validated_params|
            organization.suspend!(reason: validated_params[:reason])
            log_admin_action("suspend_organization", organization)
            OrganizationMailer.suspended(organization).deliver_later

            render json: { organization: organization_json(organization.reload) }
          end
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Organization not found" }, status: :not_found
        end

        # POST /api/v1/admin/organizations/:id/unsuspend
        #
        # No confirmation dialog and no email, mirroring the event and user
        # unsuspend paths: reversing course should be low-friction, and the
        # events come back on their own.
        def unsuspend
          organization = ::Organization.kept.find(params[:id])

          organization.unsuspend!
          log_admin_action("unsuspend_organization", organization)

          render json: { organization: organization_json(organization.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Organization not found" }, status: :not_found
        end

        # POST /api/v1/admin/organizations/:id/verify
        #
        # What unlocks creating paid events (Ticket I, #338). Distinct from a
        # user's self-service email verification: this is a human at Rally
        # deciding an organization can be trusted to take other people's money.
        def verify
          organization = ::Organization.kept.find(params[:id])

          organization.verify!(by: current_user)
          log_admin_action("verify_organization", organization)

          render json: { organization: organization_json(organization.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Organization not found" }, status: :not_found
        end

        # POST /api/v1/admin/organizations/:id/unverify
        #
        # Leaves existing paid events published — see Organization#unverify!.
        def unverify
          organization = ::Organization.kept.find(params[:id])

          organization.unverify!
          log_admin_action("unverify_organization", organization)

          render json: { organization: organization_json(organization.reload) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Organization not found" }, status: :not_found
        end

        private

        def organization_json(organization)
          {
            id: organization.id,
            slug: organization.slug,
            name: organization.name,
            logo_url: organization.logo_url,
            verified: organization.verified?,
            # #suspended? is the derived answer (this organization, or its
            # owner). suspended_directly? distinguishes the two, so staff can
            # see whether unsuspending here would actually restore it or
            # whether the owner's account is what's holding it down.
            suspended: organization.suspended?,
            suspended_directly: organization.suspended_directly?,
            suspension_reason: organization.suspension_reason,
            suspended_at: organization.suspended_at,
            events_count: organization.events.kept.count,
            owner: {
              id: organization.owner.id,
              email: organization.owner.email,
              suspended: organization.owner.suspended?
            },
            created_at: organization.created_at
          }
        end
      end
    end
  end
end
