module Api
  module V1
    class PasswordResetsController < ApplicationController
      # POST /api/v1/password_resets — request a reset email
      # Always responds 200 regardless of whether the email exists, to avoid
      # leaking which addresses are registered.
      def create
        user = User.find_by(email: params[:email]&.downcase&.strip)
        if user
          user.generate_password_reset_token!
          UserMailer.password_reset(user).deliver_later
        end

        render json: { message: "If an account exists for that email, a reset link is on its way." }
      end

      # PATCH /api/v1/password_resets/:token — set a new password
      def update
        user = User.find_by_valid_password_reset_token(params[:token])

        unless user
          render json: { error: "This reset link is invalid or has expired." }, status: :unprocessable_entity
          return
        end

        if params[:password].blank? || params[:password] != params[:password_confirmation]
          render json: { error: "Passwords must match and be present." }, status: :unprocessable_entity
          return
        end

        user.reset_password!(params[:password])
        token = JsonWebToken.encode(user_id: user.id)
        render json: { message: "Password updated.", token: token }
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end
