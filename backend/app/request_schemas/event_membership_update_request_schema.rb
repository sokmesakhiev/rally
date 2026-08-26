# frozen_string_literal: true

# Validates PATCH /api/v1/events/:event_id/members/:id (owner changing a
# member's role). Nested under :membership, matching the house convention
# for singular-resource updates (see RegistrationUpdateRequestSchema,
# RefundCreateRequestSchema).
class EventMembershipUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:membership).hash do
      required(:role).filled(:string, included_in?: EventMembership::ROLES)
    end
  end
end
