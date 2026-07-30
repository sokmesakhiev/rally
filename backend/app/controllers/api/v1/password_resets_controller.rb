module Api
  module V1
    class PasswordResetsController < BaseController
      # POST /api/v1/password_resets — request a reset email
      # Always responds 200 regardless of whether the email exists, to avoid
      # leaking which addresses are registered.
      def create
        validate_params_with_schema(PasswordResetRequestSchema) do |validated_params|
          user = User.find_by(email: validated_params[:email]&.downcase&.strip)
          if user
            user.generate_password_reset_token!
            UserMailer.password_reset(user).deliver_later
          end

          render json: { message: "If an account exists for that email, a reset link is on its way." }
        end
      end

      # PATCH /api/v1/password_resets/:token — set a new password
      def update
        user = User.find_by_valid_password_reset_token(params[:token])

        unless user
          render json: { error: "This reset link is invalid or has expired." }, status: :unprocessable_entity
          return
        end

        validate_params_with_schema(PasswordResetUpdateRequestSchema) do |validated_params|
          user.reset_password!(validated_params[:password])
          token = JsonWebToken.encode(user_id: user.id)
          render json: { message: "Password updated.", token: token }
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end
