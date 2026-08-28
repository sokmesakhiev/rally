module Api
  module V1
    # An organization's team — see organization-identity-tickets.md's Ticket D
    # (#333) and OrganizationMembership.
    #
    # Mirrors EventMembersController's shape closely on purpose: same
    # index/create/update/destroy split, same synthesized owner entry, same
    # "anyone may remove themselves" rule. Two organizations of difference:
    #
    #   * The owner is a column, not a membership row, so they can't be
    #     targeted by :id at all — "the last owner can't leave" needs no guard
    #     because there's nothing to DELETE. Handing the organization over
    #     goes through OrganizationsController#transfer_ownership.
    #   * Adding someone requires an existing Rally account, rather than
    #     emailing an invitation the way EventInvitationsController does. An
    #     invitation flow is worth having, but it's a lifecycle of its own
    #     (pending/expired/revoked rows, a mailer, an accept endpoint) and
    #     belongs in its own ticket rather than smuggled into this one.
    class OrganizationMembersController < BaseController
      include OrganizationAuthorization

      before_action :authenticate_user!
      before_action :set_organization

      # GET /api/v1/organizations/:slug/members
      # Visible to any member: you should be able to see who else is on the
      # team you're on, the same reasoning as events/:event_id/members.
      def index
        return unless require_organization_member!(@organization)

        render json: { members: members_json(@organization) }
      end

      # POST /api/v1/organizations/:slug/members
      def create
        return unless require_organization_admin!(@organization)

        validate_params_with_schema(OrganizationMemberCreateRequestSchema) do |validated_params|
          email = validated_params[:member][:email].to_s.downcase.strip
          user = User.kept.find_by(email: email)

          if user.nil?
            render json: {
              error: "No Rally account found for #{email}. They need to sign up first.",
              code: "user_not_found"
            }, status: :unprocessable_entity
            next
          end

          membership = @organization.organization_memberships
            .new(user: user, role: validated_params[:member][:role], invited_by: current_user)

          if membership.save
            render json: { member: member_json(membership) }, status: :created
          else
            # Covers both "already on the team" and "that's the owner" —
            # OrganizationMembership validates each (see #owner_is_not_a_member).
            render json: { error: membership.errors.full_messages.join(", ") },
                   status: :unprocessable_entity
          end
        end
      end

      # PATCH /api/v1/organizations/:slug/members/:id
      def update
        return unless require_organization_admin!(@organization)

        membership = @organization.organization_memberships.find(params[:id])

        validate_params_with_schema(OrganizationMembershipUpdateRequestSchema) do |validated_params|
          if membership.update(role: validated_params[:membership][:role])
            render json: { member: member_json(membership) }
          else
            render json: { error: membership.errors.full_messages.join(", ") },
                   status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Member not found" }, status: :not_found
      end

      # DELETE /api/v1/organizations/:slug/members/:id
      # An admin removes someone, OR anyone removes themselves (leaves).
      # Deliberately not admin-only: that would give a plain member no way to
      # leave except asking an admin to do it for them.
      def destroy
        membership = @organization.organization_memberships.find(params[:id])
        self_removal = membership.user_id == current_user.id

        return unless self_removal || require_organization_admin!(@organization)

        membership.destroy!

        render json: { message: self_removal ? "You have left the organization" : "Member removed" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Member not found" }, status: :not_found
      end

      private

      def set_organization
        @organization = find_organization!(
          scope: Organization.kept.includes(:owner, organization_memberships: { user: :profile })
        )
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Organization not found" }, status: :not_found
      end

      # The owner isn't a membership row (see Organization), so they're
      # synthesized as the list's first entry and the frontend never has to
      # special-case an absent owner slot. `id: nil` marks it as not a real
      # row — nothing to PATCH or DELETE against; joined_at falls back to the
      # organization's created_at, since creating it *is* how they joined.
      def members_json(organization)
        owner = organization.owner
        owner_entry = {
          id: nil,
          user_id: owner.id,
          role: "owner",
          email: owner.email,
          display_name: owner.profile&.display_name,
          avatar_url: owner.profile&.avatar_url,
          joined_at: organization.created_at
        }

        [ owner_entry ] + organization.organization_memberships.map { |m| member_json(m) }
      end

      def member_json(membership)
        {
          id: membership.id,
          user_id: membership.user_id,
          role: membership.role,
          email: membership.user.email,
          display_name: membership.user.profile&.display_name,
          avatar_url: membership.user.profile&.avatar_url,
          joined_at: membership.created_at
        }
      end
    end
  end
end
