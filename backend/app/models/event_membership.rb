# Someone other than the event's creator who helps run it — see
# db/migrate/20260826000000_create_event_memberships.rb.
#
# A row exists only once an invitation has been accepted; the pending state
# lives on EventInvitation. The creator is deliberately NOT represented here
# — they're `Event#creator_id`, and synthesizing them into member lists is
# the serializer's job, not the schema's. That keeps "who owns this event"
# a single unambiguous column rather than something you have to reconstruct
# by looking for a magic role value.
class EventMembership < ApplicationRecord
  # Mirrors the fixed-role convention used by EventActivity::ACTIONS and
  # Event::PLANS. Deliberately a small closed set rather than per-capability
  # flags — see event-membership-tickets.md for the reasoning, and the
  # forthcoming EventAuthorization concern for what each role may actually do.
  #
  # manager   — everything except delete/unpublish, plan payments, and
  #             managing other members (those spend the owner's money or
  #             change who controls the event)
  # check_in  — participant list + check-in only; the race-day volunteer
  # viewer    — read-only
  ROLES = %w[manager check_in viewer].freeze

  belongs_to :event
  belongs_to :user
  belongs_to :invited_by, class_name: "User", optional: true

  validates :role, presence: true, inclusion: { in: ROLES }
  # Mirrors the unique index so a duplicate surfaces as a validation error
  # rather than an ActiveRecord::RecordNotUnique 500.
  validates :user_id, uniqueness: { scope: :event_id, message: "is already a member of this event" }

  scope :managers, -> { where(role: "manager") }

  ROLES.each do |role_name|
    define_method("#{role_name}?") { role == role_name }
  end
end
