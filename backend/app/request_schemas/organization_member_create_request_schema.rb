# frozen_string_literal: true

# Validates POST /api/v1/organizations/:slug/members.
#
# Addressed by email rather than user_id: an organizer knows their colleague's
# email address, not the uuid Rally happens to store. The controller resolves
# it to an existing account and refuses when there isn't one — see the note
# there about why this doesn't send invitations the way event membership does.
class OrganizationMemberCreateRequestSchema < ApplicationRequestSchema
  params do
    required(:member).hash do
      required(:email).filled(:string)
      required(:role).filled(:string, included_in?: OrganizationMembership::ROLES)
    end
  end
end
