module Api
  module V1
    class EmailVerificationsController < ApplicationController
      before_action :authenticate_user!, only: [ :create ]

      # POST /api/v1/email_verifications — resend the verification email
      def create
        if current_user.email_verified?
          render json: { message: "Email already verified." }
          return
        end

        current_user.generate_email_verification_token!
        UserMailer.email_verification(current_user).deliver_later
        render json: { message: "Verification email sent." }
      end

      # GET /api/v1/email_verifications/:token — confirm the address
      def show
        user = User.find_by_valid_email_verification_token(params[:token])

        unless user
          render json: { error: "This verification link is invalid or has expired." }, status: :unprocessable_entity
          return
        end

        user.verify_email!
        render json: { message: "Email verified." }
      end
    end
  end
end
