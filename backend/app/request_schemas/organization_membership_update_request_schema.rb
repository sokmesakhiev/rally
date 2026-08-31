# frozen_string_literal: true

# Validates PATCH /api/v1/organizations/:slug/members/:id (changing a
# member's role). Nested under :membership, matching
# EventMembershipUpdateRequestSchema and the house convention for
# singular-resource updates.
class OrganizationMembershipUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:membership).hash do
      required(:role).filled(:string, included_in?: OrganizationMembership::ROLES)
    end
  end
end
