# frozen_string_literal: true

# Validates POST /api/v1/password_resets. Presence only, no format check —
# the endpoint already returns the same generic "if an account exists..."
# message for any email, matched or not, to avoid leaking which addresses
# are registered. Rejecting a blank/missing email outright is a shape fix
# (previously silently no-op'd to the same generic message), not a change
# to that enumeration protection.
class PasswordResetRequestSchema < ApplicationRequestSchema
  params do
    required(:email).filled(:string)
  end
end
