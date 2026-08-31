# frozen_string_literal: true

# Shared gates for the two organization-facing controllers — see
# organization-identity-tickets.md's Ticket D (#333).
#
# Deliberately much smaller than EventAuthorization. Events need a
# capability × role matrix because a dozen endpoints each permit a different
# slice of five roles; an organization has three tiers (owner, admin, plain
# member) and a handful of endpoints, so a matrix here would be indirection
# without payoff. If org-level permissions ever grow past this, that's the
# point to reach for the same CAPABILITIES shape.
#
# On 404-vs-403: looking up by slug, a caller with no relationship to the
# organization gets 404 — the same "don't confirm it exists" reasoning the
# admin namespace uses, and consistent with find_authorized_event!. Once
# they're on the team but their tier doesn't cover the action, they get 403,
# because at that point the resource's existence is already known to them.
module OrganizationAuthorization
  extend ActiveSupport::Concern

  private

  # Loads by slug (Organization#to_param), scoped to non-deleted by default.
  # Raises ActiveRecord::RecordNotFound so each caller keeps rendering its
  # own "Organization not found" copy, matching find_authorized_event!.
  def find_organization!(slug = params[:slug], scope: Organization.kept)
    scope.find_by!(slug: slug)
  end

  # Any relationship at all — owner, admin, or plain member. Used for reads
  # of the management view: you should be able to see the organization you
  # belong to, even if you can't change it.
  def require_organization_member!(organization)
    return true if organization.member?(current_user)

    # 404 rather than 403: a stranger has no relationship with this
    # organization, so don't confirm the slug exists.
    render json: { error: "Organization not found" }, status: :not_found
    false
  end

  # Owner or admin — everything except deleting the organization,
  # transferring ownership, and payment settings.
  def require_organization_admin!(organization)
    return true if organization.administered_by?(current_user)

    return false unless require_organization_member!(organization)

    render json: { error: "Forbidden" }, status: :forbidden
    false
  end

  # Owner only. Deleting the organization, transferring it, and connecting a
  # PayWay account all decide where other people's money goes or whether the
  # brand keeps existing — not an admin's call.
  def require_organization_owner!(organization)
    return true if organization.owner?(current_user)

    return false unless require_organization_member!(organization)

    render json: { error: "Forbidden" }, status: :forbidden
    false
  end
end
