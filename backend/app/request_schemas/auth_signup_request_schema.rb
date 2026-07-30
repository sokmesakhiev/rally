# frozen_string_literal: true

# Validates POST /api/v1/auth/signup. Params are top-level (not nested under
# a "user" key) — matches what authApi.signup actually posts. Password
# length/confirmation still lives on User (has_secure_password +
# `validates :password, length: { minimum: 8 }`), so AuthController#signup
# keeps its rescue ActiveRecord::RecordInvalid — this schema only rejects
# clearly-malformed requests early (missing email/password entirely).
class AuthSignupRequestSchema < ApplicationRequestSchema
  params do
    required(:email).filled(:string)
    required(:password).filled(:string)
    optional(:display_name).maybe(:string)
  end
end
