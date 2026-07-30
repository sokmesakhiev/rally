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
  # Uses .size, not .count: .count always issues a fresh SELECT COUNT(*),
  # even when registration_event_types has already been eager-loaded
  # (.includes(event_types: :registration_event_types)) — which defeats the
  # whole point of eager-loading and turns any listing of events with types
  # (e.g. EventsController#index, the public events page) into an N+1.
  # .size uses the preloaded array when present, and falls back to a COUNT
  # query only when the association hasn't been loaded (e.g. here from a
  # single record, like the capacity check on registration create).
  def spots_remaining
    return nil if capacity.nil?
    taken = registration_event_types.size
    [ capacity - taken, 0 ].max
  end

  def full?
    return false if capacity.nil?
    registration_event_types.size >= capacity
  end
end
