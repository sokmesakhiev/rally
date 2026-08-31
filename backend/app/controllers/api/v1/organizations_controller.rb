module Api
  module V1
    # Managing the identity an event is presented under — see
    # organization-identity-tickets.md's Ticket D (#333).
    #
    # This is the *management* surface, and every action requires a
    # relationship with the organization. The public organizer page (identity,
    # events, trust signals, no auth) is Ticket F (#335); keep the two apart,
    # because this payload deliberately carries things — PayWay status, the
    # owner's identity — that must never appear on a public page.
    #
    # Branding images go through UploadsController (type "logo"/"banner"),
    # which already validates content type and size; this endpoint only ever
    # stores the resulting URL.
    class OrganizationsController < BaseController
      include OrganizationAuthorization

      before_action :authenticate_user!

      # GET /api/v1/organizations
      # The org switcher's data source: everything the caller may act for,
      # not a public directory. Plain memberships are excluded because they
      # grant no authority — see Organization#administered_by?.
      def index
        organizations = current_user.administered_organizations.kept.order(:name)

        render json: { organizations: organizations.map { |o| organization_json(o) } }
      end

      # POST /api/v1/organizations
      def create
        validate_params_with_schema(OrganizationRequestSchema) do |validated_params|
          organization = Organization.new(validated_params[:organization])
          organization.owner = current_user

          if organization.save
            render json: { organization: organization_json(organization) }, status: :created
          else
            render json: { error: organization.errors.full_messages.join(", ") },
                   status: :unprocessable_entity
          end
        end
      end

      # GET /api/v1/organizations/:slug
      def show
        organization = find_organization!
        return unless require_organization_member!(organization)

        render json: { organization: organization_json(organization) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Organization not found" }, status: :not_found
      end

      # PATCH /api/v1/organizations/:slug
      def update
        organization = find_organization!
        return unless require_organization_admin!(organization)

        validate_params_with_schema(OrganizationUpdateRequestSchema) do |validated_params|
          attrs = validated_params[:organization]

          # PayWay credentials decide where other people's registration money
          # lands, so they're owner-only even though admins may edit
          # everything else. Rejecting outright (rather than silently
          # dropping the keys) so an admin isn't told their change saved when
          # it didn't.
          if attrs.slice(*PAYWAY_ATTRS).any? && !organization.owner?(current_user)
            render json: {
              error: "Only the organization's owner can change payment settings.",
              code: "owner_required"
            }, status: :forbidden
            next
          end

          if organization.update(attrs)
            render json: { organization: organization_json(organization) }
          else
            render json: { error: organization.errors.full_messages.join(", ") },
                   status: :unprocessable_entity
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Organization not found" }, status: :not_found
      end

      # DELETE /api/v1/organizations/:slug
      # Soft-delete, matching Event#discard! — the row stays so historical
      # events, payments and audit entries still resolve.
      def destroy
        organization = find_organization!
        return unless require_organization_owner!(organization)

        unless organization.discardable?
          render json: {
            error: "This organization still presents events. Delete or transfer them first.",
            code: "organization_has_events"
          }, status: :unprocessable_entity
          return
        end

        organization.discard!
        render json: { message: "Organization deleted" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Organization not found" }, status: :not_found
      end

      # POST /api/v1/organizations/:slug/transfer_ownership
      #
      # The only way ownership moves. Restricted to an existing admin so
      # ownership can't be handed to someone who has never been on the team —
      # this transfers the PayWay credentials and the right to delete the
      # organization, so the target should already be trusted with it.
      #
      # The outgoing owner becomes an admin rather than dropping off the team
      # entirely: losing all access to an organization you just handed over is
      # rarely what anyone means, and re-adding yourself is impossible once
      # you're not on it.
      def transfer_ownership
        organization = find_organization!
        return unless require_organization_owner!(organization)

        validate_params_with_schema(OrganizationTransferOwnershipRequestSchema) do |validated_params|
          membership = organization.organization_memberships
            .admins.find_by(user_id: validated_params[:user_id])

          if membership.nil?
            render json: {
              error: "Choose an existing admin of this organization to transfer ownership to.",
              code: "admin_required"
            }, status: :unprocessable_entity
            next
          end

          previous_owner_id = organization.owner_id
          new_owner_id = membership.user_id

          Organization.transaction do
            # Order matters: the new owner's membership row has to go before
            # owner_id changes, or OrganizationMembership's
            # #owner_is_not_a_member validation would reject the row that
            # already exists.
            membership.destroy!
            organization.update!(owner_id: new_owner_id)
            organization.organization_memberships.create!(user_id: previous_owner_id, role: "admin")
          end

          render json: { organization: organization_json(organization.reload) }
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Organization not found" }, status: :not_found
      end

      private

      PAYWAY_ATTRS = %i[payway_merchant_id payway_api_key payway_rsa_public_key].freeze

      # The management payload. Distinct from Ticket F's public one, which
      # must not carry payway_* or the owner's identity.
      def organization_json(organization)
        {
          id: organization.id,
          slug: organization.slug,
          name: organization.name,
          description: organization.description,
          logo_url: organization.logo_url,
          banner_url: organization.banner_url,
          brand_color: organization.brand_color,
          website: organization.website,
          contact_email: organization.contact_email,
          contact_phone: organization.contact_phone,
          facebook_url: organization.facebook_url,
          instagram_url: organization.instagram_url,
          telegram_url: organization.telegram_url,
          verified: organization.verified?,
          suspended: organization.suspended?,
          owner_id: organization.owner_id,
          # Publish-readiness (Ticket E, #334). Surfaced so the settings page
          # can render the checklist from the server's rule rather than
          # re-deriving it and drifting. `identity_required` tells the
          # frontend whether the gate is currently enforced — see
          # Organization.identity_required_for_publishing?.
          identity_complete: organization.identity_complete?,
          missing_identity_fields: organization.missing_identity_fields,
          identity_required: Organization.identity_required_for_publishing?,
          # What the caller may do, so the frontend doesn't re-derive the
          # rules and drift from the server's answer.
          role: role_for(organization),
          # Never the plaintext key — only enough to confirm what's saved.
          payway_merchant_id: organization.payway_merchant_id,
          payway_api_key_masked: organization.payway_api_key_masked,
          payway_configured: organization.payway_configured?,
          payway_refund_configured: organization.payway_refund_configured?,
          events_count: organization.events.kept.count,
          created_at: organization.created_at,
          updated_at: organization.updated_at
        }
      end

      def role_for(organization)
        return "owner" if organization.owner?(current_user)
        return "admin" if organization.administered_by?(current_user)
        return "member" if organization.member?(current_user)

        nil
      end
    end
  end
end
