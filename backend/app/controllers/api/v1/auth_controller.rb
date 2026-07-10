module Api
  module V1
    class AuthController < ApplicationController
      before_action :authenticate_user!, only: [ :me ]

      # POST /api/v1/auth/signup
      def signup
        user = User.new(
          email: params[:email],
          password: params[:password],
          password_confirmation: params[:password]
        )

        if params[:display_name].present?
          user.save!
          user.profile.update!(display_name: params[:display_name].strip)
        else
          user.save!
        end

        UserMailer.email_verification(user).deliver_later

        token = JsonWebToken.encode(user_id: user.id)
        render json: user_payload(user, token), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/auth/signin
      def signin
        user = User.find_by(email: params[:email]&.downcase&.strip)

        unless user&.authenticate(params[:password])
          render json: { error: "Invalid email or password" }, status: :unauthorized
          return
        end

        token = JsonWebToken.encode(user_id: user.id)
        render json: user_payload(user, token)
      end

      # GET /api/v1/auth/me
      def me
        render json: user_payload(current_user, nil).except(:token)
      end

      private

      def user_payload(user, token)
        profile = user.profile
        payload = {
          user: {
            id: user.id,
            email: user.email,
            display_name: profile&.display_name,
            avatar_url: profile&.avatar_url,
            email_verified: user.email_verified?,
            created_at: user.created_at
          }
        }
        payload[:token] = token if token
        payload
      end
    end
  end
end
