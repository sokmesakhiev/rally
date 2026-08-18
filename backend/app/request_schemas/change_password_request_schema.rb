# frozen_string_literal: true

# Validates PATCH /api/v1/auth/password — logged-in password change, distinct
# from PasswordResetUpdateRequestSchema's token-based forgot-password flow.
# new_password's minimum length still lives on User
# (`validates :password, length: { minimum: 8 }`), not duplicated here — see
# PasswordResetUpdateRequestSchema's class comment for the same reasoning.
class ChangePasswordRequestSchema < ApplicationRequestSchema
  params do
    required(:current_password).filled(:string)
    required(:new_password).filled(:string)
    required(:new_password_confirmation).filled(:string)
  end

  rule(:new_password, :new_password_confirmation) do
    if values[:new_password] != values[:new_password_confirmation]
      key(:new_password_confirmation).failure("must match new password")
    end
  end
end
