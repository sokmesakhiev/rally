# frozen_string_literal: true

# Validates PATCH /api/v1/password_resets/:token. The token itself is a
# path segment, not part of this schema — its validity is checked
# separately in the controller before this schema even runs (see
# PasswordResetsController#update). Minimum length (8 chars) is
# deliberately NOT duplicated here — that already lives on User
# (`validates :password, length: { minimum: 8 }`), enforced via
# User#reset_password! and the controller's rescue ActiveRecord::RecordInvalid.
# Duplicating the exact threshold here would just be one more place it could
# drift out of sync if it ever changes.
class PasswordResetUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:password).filled(:string)
    required(:password_confirmation).filled(:string)
  end

  rule(:password, :password_confirmation) do
    if values[:password] != values[:password_confirmation]
      key(:password_confirmation).failure("must match password")
    end
  end
end
