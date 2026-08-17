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
          profile = current_user.profile || current_user.create_profile!
          if profile.update(validated_params[:profile])
            render json: { profile: profile_json(profile) }
          else
            render json: { error: profile.errors.full_messages.join(", ") }, status: :unprocessable_entity
          end
        end
      end

      private

      def profile_json(profile)
        {
          id: profile&.id,
          user_id: current_user.id,
          display_name: profile&.display_name,
          avatar_url: profile&.avatar_url,
          # Never the plaintext key — only enough to confirm what's saved.
          payway_merchant_id: profile&.payway_merchant_id,
          payway_api_key_masked: profile&.payway_api_key_masked,
          payway_configured: profile&.payway_configured? || false,
          # Not a secret (it's a public key — see Profile#payway_refund_configured?)
          # so no masking needed, but the frontend only needs to know refund
          # capability is on, not see the raw PEM block.
          payway_refund_configured: profile&.payway_refund_configured? || false,
          created_at: profile&.created_at,
          updated_at: profile&.updated_at
        }
      end
    end
  end
end
