# frozen_string_literal: true

# Validates POST /api/v1/auth/google. A missing id_token would otherwise
# get fed straight into Google::Auth::IDTokens.verify_oidc and come back
# as a generic "Invalid Google credential" — this gives a clearer error
# for the pure "forgot to send it" case without touching Google at all.
class AuthGoogleRequestSchema < ApplicationRequestSchema
  params do
    required(:id_token).filled(:string)
  end
end
