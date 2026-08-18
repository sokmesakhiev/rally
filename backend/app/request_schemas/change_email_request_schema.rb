# frozen_string_literal: true

# Validates PATCH /api/v1/auth/email. current_password is required — proving
# the session's owner also knows the account password stops a hijacked
# session token from silently redirecting account-recovery email to an
# attacker's address (a well-known account-takeover pattern), the same
# reason Api::V1::AuthController#delete_account requires it too. Email
# format/uniqueness stay on User (`validates :email, ...`), not duplicated
# here — this schema only rejects a clearly-missing value early.
class ChangeEmailRequestSchema < ApplicationRequestSchema
  params do
    required(:current_password).filled(:string)
    required(:new_email).filled(:string)
  end
end
