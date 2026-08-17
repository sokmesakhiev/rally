class EventType < ApplicationRecord
  belongs_to :event
  has_many   :registration_event_types, dependent: :destroy
  has_many   :registrations, through: :registration_event_types

  validates :name,     presence: true, length: { maximum: 120 }
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :capacity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # Effective price — falls back to event price if nil
  def effective_price_cents
    price_cents.nil? ? event.price_cents : price_cents
  end

  # How many spots are left (nil = unlimited)
  #
  # Uses .size (via #active_registration_event_types), not .count: .count
  # always issues a fresh SELECT COUNT(*), even when registration_event_types
  # has already been eager-loaded (.includes(event_types: {
  # registration_event_types: :registration })) — which defeats the whole
  # point of eager-loading and turns any listing of events with types (e.g.
  # EventsController#index, the public events page) into an N+1. .size uses
  # the preloaded array when present, and falls back to a COUNT query only
  # when the association hasn't been loaded (e.g. here from a single record,
  # like the capacity check on registration create).
  def spots_remaining
    return nil if capacity.nil?
    taken = active_registration_event_types.size
    [ capacity - taken, 0 ].max
  end

  def full?
    return false if capacity.nil?
    active_registration_event_types.size >= capacity
  end

  private

  # A cancelled registration (full refund — see Refunds::IssueRefund) no
  # longer holds this type's slot either, but its RegistrationEventType row
  # is deliberately kept (not destroyed) so "what type were they registered
  # for" survives as history. That means the raw join-table count is no
  # longer the right number — this filters it out.
  #
  # When registration_event_types is preloaded, .reject stays in memory (no
  # query) as long as :registration was *also* preloaded alongside it —
  # otherwise touching ret.registration below would itself be an N+1. See
  # the callers' .includes chains (event_types: { registration_event_types:
  # :registration }}). When unloaded, this issues one filtered COUNT query,
  # same cost as the plain .size fallback it replaces.
  def active_registration_event_types
    if registration_event_types.loaded?
      registration_event_types.reject { |ret| ret.registration.status == "cancelled" }
    else
      registration_event_types.joins(:registration).where.not(registrations: { status: "cancelled" })
    end
  end
end
