# frozen_string_literal: true

# Validates POST /api/v1/organizations/:slug/transfer_ownership.
#
# user_id, not email: transferring an organization hands over its payment
# credentials and the ability to delete it, so the caller should be naming
# someone already visible to them in the members list rather than typing an
# address and hoping. The controller additionally requires the target to be an
# existing admin — see there.
class OrganizationTransferOwnershipRequestSchema < ApplicationRequestSchema
  params do
    required(:user_id).filled(:string)
  end
end
