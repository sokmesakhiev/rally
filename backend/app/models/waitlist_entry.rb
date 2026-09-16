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
  # A closed event accepts nothing — not a registration, not a waitlist entry.
  # The waitlist exists to catch people when an event is *full*, i.e. when
  # spots might still free up; once the organizer has closed sign-ups there is
  # nothing to wait for, and collecting names would promise something the
  # organizer has just said they aren't doing.
  #
  # `on: :create` here does NOT mean existing entries survive a closure and get
  # promoted later. This comment used to claim exactly that ("closing doesn't
  # strand people who were queueing before it happened") and it was wrong:
  # promotion creates a Registration, Registration validates
  # `registration_is_open` on create too, so every promotion on a closed event
  # raised and was swallowed by Waitlists::PromoteNext's rescue — the entry sat
  # "waiting" forever, silently.
  #
  # What actually happens now is that closing is final and the queue is told:
  # Waitlists::CancelForClosedEvent cancels every waiting entry and notifies its
  # owner, run inline when an organizer presses Close and hourly by
  # CancelWaitlistsForClosedEventsJob for the deadline path. So `on: :create`
  # here buys only the ordinary thing — an entry already in the table stays
  # valid on later saves — and never outlives the closure.
  validate :registration_is_open, on: :create
  validate :event_not_suspended, on: :create

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

  def registration_is_open
    return if event.nil? || event.accepting_signups?

    errors.add(:base, :registration_closed, message: "Registration for this event is closed")
  end

  # Mirrors Registration#event_not_suspended — see its comment. Both sign-up
  # paths need it, and for the same reason: nothing in this model or the
  # controller looked at `suspended_at`, so a suspended event still took
  # queue entries.
  def event_not_suspended
    return if event.nil? || !event.suspended?

    errors.add(:base, :event_suspended, message: "This event is not currently accepting registrations")
  end

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
