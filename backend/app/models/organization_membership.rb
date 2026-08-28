# Someone other than the owner who can act on behalf of an Organization —
# see organization-identity-tickets.md's Ticket A (#330).
#
# Holds "admin" and "member" only. The owner is Organization#owner_id, never
# a row here, so there is no way to end up with two owners or none.
#
# Deliberately distinct from EventMembership, which answers a different
# question: this is "can you act for this organization", EventMembership is
# "can you help run this specific event". A volunteer scanning tickets at one
# race gets an EventMembership with role check_in and no OrganizationMembership
# at all.
class OrganizationMembership < ApplicationRecord
  # Ordered least → most privileged, matching EventMembership::ROLES' shape.
  # "owner" is deliberately absent — see the class comment.
  ROLES = %w[member admin].freeze

  belongs_to :organization
  belongs_to :user
  belongs_to :invited_by, class_name: "User", optional: true

  validates :role, inclusion: { in: ROLES }
  # Mirrors the DB's unique index so a duplicate surfaces as a validation
  # error rather than a 500.
  validates :user_id, uniqueness: { scope: :organization_id }

  validate :owner_is_not_a_member

  scope :admins, -> { where(role: "admin") }

  def admin?
    role == "admin"
  end

  private

  # The owner's authority comes from Organization#owner_id. A membership row
  # for them would be a second, contradictable source of truth — and would
  # make Organization#team return them twice.
  def owner_is_not_a_member
    return if organization.nil? || user_id.nil?
    return unless organization.owner_id == user_id

    errors.add(:user_id, "already owns this organization")
  end
end
