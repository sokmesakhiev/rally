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
  # Kept intentionally narrow — only the two gaps actually asked for
  # (removing a participant, and the price/date fields organizers most
  # often change after publishing — see Event#price_cents/#start_at/#end_at
  # and change-event-plan-tickets.md's "Ticket B" for why those two in
  # particular matter once people may already be registered). Add more
  # here if broader event-activity coverage is wanted later.
  ACTIONS = %w[remove_participant update_event_details].freeze

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
