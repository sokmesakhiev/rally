# frozen_string_literal: true

# Validates DELETE /api/v1/auth/account. current_password is required — see
# ChangeEmailRequestSchema's class comment for why a bearer token alone
# isn't enough authorization for an irreversible, identity-changing action.
class DeleteAccountRequestSchema < ApplicationRequestSchema
  params do
    required(:current_password).filled(:string)
  end
end
