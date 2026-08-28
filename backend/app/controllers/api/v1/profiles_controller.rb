module Api
  module V1
    class ProfilesController < BaseController
      before_action :authenticate_user!

      # GET /api/v1/profile
      def show
        render json: { profile: profile_json(current_user.profile) }
      end

      # PATCH /api/v1/profile
      def update
        validate_params_with_schema(ProfileUpdateRequestSchema) do |validated_params|
          attrs = validated_params[:profile]
          payway_attrs = attrs.slice(*PAYWAY_ATTRS)
          profile = current_user.profile || current_user.create_profile!

          # See #update_payway_credentials! — renders and returns false when
          # the caller has no single organization to write to.
          next unless payway_attrs.empty? || update_payway_credentials!(payway_attrs)

          if profile.update(attrs.except(*PAYWAY_ATTRS))
            render json: { profile: profile_json(profile.reload) }
          else
            render json: { error: profile.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      end

      private

      # ── TRANSITIONAL, remove with Ticket G (#336) ──────────────────────────
      # PayWay credentials moved to Organization in Ticket B (#331), but the
      # frontend's payment-settings form still reads and writes them through
      # this endpoint until #336 moves that UI to organization settings.
      # Proxying here keeps organizers able to manage their payment account in
      # the meantime; dropping the fields outright would leave them unable to
      # connect or change a PayWay account at all until #336 ships.
      #
      # When #336 lands: delete everything marked TRANSITIONAL here, and drop
      # the payway_* keys from ProfileUpdateRequestSchema.
      PAYWAY_ATTRS = %i[payway_merchant_id payway_api_key payway_rsa_public_key].freeze

      # TRANSITIONAL — the organization these proxied reads/writes act on.
      # Only unambiguous when the user owns exactly one; PayWay credentials are
      # owner-level, so administered-but-not-owned organizations don't count.
      def proxied_payway_organizations
        @proxied_payway_organizations ||= current_user.owned_organizations.kept.order(:created_at, :id).to_a
      end

      # TRANSITIONAL — writes proxied credentials to that single organization.
      # Returns false (having rendered) when there isn't exactly one, rather
      # than guessing which of an organizer's accounts should take the money.
      def update_payway_credentials!(payway_attrs)
        organizations = proxied_payway_organizations

        if organizations.length != 1
          render json: {
            error: organizations.empty? ?
              "Create an organization before connecting a PayWay account." :
              "You own more than one organization. Set payment details on the organization itself.",
            code: "organization_required"
          }, status: :unprocessable_entity
          return false
        end

        organization = organizations.first
        return true if organization.update(payway_attrs)

        render json: {
          error: organization.errors.full_messages.join(", ")
        }, status: :unprocessable_entity
        false
      end

      def profile_json(profile)
        # TRANSITIONAL — see PAYWAY_ATTRS. Reads back from the organization so
        # the settings page reflects what was actually saved.
        organization = proxied_payway_organizations.first

        {
          id: profile&.id,
          user_id: current_user.id,
          display_name: profile&.display_name,
          avatar_url: profile&.avatar_url,
          phone: profile&.phone,
          # See UserPayload for the fuller explanation — same "add your
          # real email" signal, just surfaced here too since the account
          # settings page loads this endpoint, not /auth/me, to render its
          # own fields.
          email_auto_generated: current_user.email_auto_generated?,
          # Never the plaintext key — only enough to confirm what's saved.
          payway_merchant_id: organization&.payway_merchant_id,
          payway_api_key_masked: organization&.payway_api_key_masked,
          payway_configured: organization&.payway_configured? || false,
          # Not a secret (it's a public key — see Organization#payway_refund_configured?)
          # so no masking needed, but the frontend only needs to know refund
          # capability is on, not see the raw PEM block.
          payway_refund_configured: organization&.payway_refund_configured? || false,
          notify_payment_received: profile&.notify_payment_received? != false,
          notify_refund_issued: profile&.notify_refund_issued? != false,
          notify_promoted_from_waitlist: profile&.notify_promoted_from_waitlist? != false,
          notify_event_details_changed: profile&.notify_event_details_changed? != false,
          created_at: profile&.created_at,
          updated_at: profile&.updated_at
        }
      end
    end
  end
end
