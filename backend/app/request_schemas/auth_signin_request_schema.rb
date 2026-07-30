# frozen_string_literal: true

# Validates POST /api/v1/auth/signin. Deliberately shape-only (presence,
# not format/length) — the actual credential check stays in the model
# (User#authenticate) and keeps returning the same generic "Invalid email
# or password" either way, so this doesn't change what an incorrect
# guess reveals.
class AuthSigninRequestSchema < ApplicationRequestSchema
  params do
    required(:email).filled(:string)
    required(:password).filled(:string)
  end
end
