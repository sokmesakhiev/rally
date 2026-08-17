class WaitlistEntry < ApplicationRecord
  belongs_to :event
  belongs_to :user

  STATUSES = %w[waiting promoted cancelled].freeze

  validates :status, inclusion: { in: STATUSES }
  # Mirrors the partial unique index in the migration — a user can only have
  # one *active* waitlist spot per event at a time, but can rejoin later
  # (e.g. after leaving) once that earlier row is no longer "waiting".
  validates :user_id, uniqueness: {
    scope: :event_id,
    conditions: -> { where(status: "waiting") },
    message: "you're already on the waitlist for this event"
  }
  validate :not_already_registered, on: :create
  validate :event_or_requested_types_actually_full, on: :create

  scope :waiting, -> { where(status: "waiting") }

  # Soft-delete — see Event#discard!, the only current caller (cascading
  # when an organizer/admin discards the whole event). Setting status to
  # "cancelled" alongside deleted_at means the existing :waiting scope
  # already excludes discarded entries with no extra filtering needed at
  # call sites — same pattern as Registration#discard!.
  scope :kept, -> { where(deleted_at: nil) }
  scope :discarded, -> { where.not(deleted_at: nil) }

  def discard!
    update!(deleted_at: Time.current, status: "cancelled")
  end

  def discarded?
    deleted_at.present?
  end

  private

  def not_already_registered
    return unless event && user
    if user.registrations.exists?(event_id: event.id)
      errors.add(:base, :already_registered, message: "You're already registered for this event")
    end
  end

  # Joining a waitlist only makes sense if a normal registration would
  # actually have been rejected — otherwise someone could "queue" for a spot
  # that's sitting open. Mirrors the two ways Registration/RegistrationEventType
  # reject a create: the event itself is at capacity, or (independently) one
  # of the requested types is.
  def event_or_requested_types_actually_full
    return unless event
    requested_types = event.event_types.where(id: Array(event_type_ids).compact.reject(&:empty?))
    return if event.full? || requested_types.any?(&:full?)
    errors.add(:base, :not_full, message: "This event isn't full yet — register normally instead")
  end
end
