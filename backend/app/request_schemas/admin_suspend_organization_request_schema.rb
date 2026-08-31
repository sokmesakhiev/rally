# frozen_string_literal: true

# Validates POST /api/v1/admin/organizations/:id/suspend. The reason is
# required — same up-front decision as AdminSuspendEventRequestSchema: a
# suspension always carries a reason, and that reason is emailed to the owner
# verbatim so they have something concrete to dispute.
class AdminSuspendOrganizationRequestSchema < ApplicationRequestSchema
  MAX_REASON_LENGTH = 500

  params do
    required(:reason).filled(:string, max_size?: MAX_REASON_LENGTH)
  end
end
