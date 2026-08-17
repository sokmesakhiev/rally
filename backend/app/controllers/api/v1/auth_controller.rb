module Api
  module V1
    class AuthController < BaseController
      before_action :authenticate_user!, only: [ :me ]

      # POST /api/v1/auth/signup
      def signup
        validate_params_with_schema(AuthSignupRequestSchema) do |validated_params|
          recaptcha = RecaptchaVerifier.verify(
            validated_params[:recaptcha_token],
            action: "signup",
            remote_ip: request.remote_ip
          )
          unless recaptcha.success?
            render json: { error: "Captcha verification failed. Please try again.", code: "recaptcha_failed" },
                   status: :unprocessable_entity
            return
          end

          user = User.new(
            email: validated_params[:email],
            password: validated_params[:password],
            password_confirmation: validated_params[:password]
          )

          if validated_params[:display_name].present?
            user.save!
            user.profile.update!(display_name: validated_params[:display_name].strip)
          else
            user.save!
          end

          UserMailer.email_verification(user).deliver_later

          token = JsonWebToken.encode(user_id: user.id)
          render json: user_payload(user, token), status: :created
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # POST /api/v1/auth/signin
      def signin
        validate_params_with_schema(AuthSigninRequestSchema) do |validated_params|
          user = User.find_by(email: validated_params[:email]&.downcase&.strip)

          unless user&.authenticate(validated_params[:password])
            render json: { error: "Invalid email or password" }, status: :unauthorized
            return
          end

          token = JsonWebToken.encode(user_id: user.id)
          render json: user_payload(user, token)
        end
      end

      # POST /api/v1/auth/google
      # Body: { id_token: "<Google ID token from Google Identity Services>" }
      #
      # The frontend never talks to Google's OAuth token endpoint directly —
      # it uses Google Identity Services' JS SDK to get a signed ID token,
      # and this action is the only place that token is verified (signature,
      # expiry, issuer, and that it was issued for *our* GOOGLE_CLIENT_ID).
      # See config/initializers or GOOGLE_CLIENT_ID in production.rb wiring
      # (infrastructure/ecs.tf) for where the client ID comes from.
      def google
        validate_params_with_schema(AuthGoogleRequestSchema) do |validated_params|
          payload = Google::Auth::IDTokens.verify_oidc(validated_params[:id_token], aud: ENV.fetch("GOOGLE_CLIENT_ID", nil))

          user = User.find_or_create_from_google!(
            google_uid: payload["sub"],
            email: payload["email"],
            email_verified: ActiveModel::Type::Boolean.new.cast(payload["email_verified"]),
            name: payload["name"]
          )

          token = JsonWebToken.encode(user_id: user.id)
          render json: user_payload(user, token)
        end
      rescue Google::Auth::IDTokens::VerificationError => e
        render json: { error: "Invalid Google credential: #{e.message}" }, status: :unauthorized
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
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
            # Drives whether the frontend shows the admin nav link. Not a
            # security boundary — every admin endpoint checks server-side via
            # require_admin! regardless of what the client believes.
            admin: user.admin?,
            created_at: user.created_at
          }
        }
        payload[:token] = token if token
        payload
      end
    end
  end
end
