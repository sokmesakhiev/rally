# frozen_string_literal: true

# Validates POST /api/v1/admin/events/:id/suspend.
#
# Unlike AdminSuspendUserRequestSchema's `reason` (optional), this one is
# required — see event-freeze-and-terms-tickets.md's up-front decision: a
# suspension is sent to the event owner verbatim in an email explaining why
# their event was suspended, so an admin has to actually write something
# before the lockdown lands, not just click a button.
class AdminSuspendEventRequestSchema < ApplicationRequestSchema
  MAX_REASON_LENGTH = 500

  params do
    required(:reason).filled(:string, max_size?: MAX_REASON_LENGTH)
  end
end
