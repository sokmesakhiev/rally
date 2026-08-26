# Queryable activity log for organizer-level actions on their own event —
# see db/migrate/20260825000000_create_event_activities.rb for why this is
# deliberately separate from AdminAction (that one's scoped to Rally-staff
# moderation only). Read via Api::V1::EventsController#activity, organizer
# of the event only — see that action's authorization.
#
# Deliberately append-only, same convention as AdminAction: no updated_at
# (nothing should ever mutate a past entry), no model-level destroy guard
# since nothing in the app calls #destroy on it.
class EventActivity < ApplicationRecord
  # Kept intentionally narrow — only the gaps actually asked for (removing a
  # participant, the price/date fields organizers most often change after
  # publishing — see Event#price_cents/#start_at/#end_at and
  # change-event-plan-tickets.md's "Ticket B" — and, as of event membership's
  # Tickets D/E, sending/revoking a team invitation and a recipient
  # accepting one). remove_member/change_member_role are Tickets F/H's
  # concern, added when those land, not here.
  ACTIONS = %w[remove_participant update_event_details invite_member revoke_invitation member_joined].freeze

  belongs_to :event
  belongs_to :actor, class_name: "User"

  validates :action, presence: true, inclusion: { in: ACTIONS }

  scope :recent, -> { order(created_at: :desc) }

  class << self
    def log!(event:, actor:, action:, metadata: {})
      create!(event: event, actor: actor, action: action, metadata: metadata)
    end
  end
end
