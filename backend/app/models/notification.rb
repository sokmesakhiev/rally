# An in-app notification — one row per thing a user should know about, and
# what the header bell counts.
#
# The persistent channel of the three. Mailers reach everyone by email; web
# push reaches subscribed devices and is gone once dismissed; this survives a
# reload, which is what makes a badge count possible at all.
#
# Written by Notifications::RegistrationNotifier alongside the push, so the
# wording of a given event exists in exactly one place.
class Notification < ApplicationRecord
  belongs_to :user
  # Optional — not every notification is about an event. dependent: :destroy on
  # the Event side would be wrong (events are soft-deleted, see Event#discard!),
  # so this is just a link for deep-linking and filtering.
  belongs_to :event, optional: true

  # Mirrors the mailer and push trigger names. Kept in sync with
  # Notifications::RegistrationNotifier's public methods.
  KINDS = %w[
    registration_confirmed
    payment_received
    promoted_from_waitlist
    refund_issued
    event_details_changed
  ].freeze

  # How many the bell shows before giving up on precision. A badge reading
  # "99+" is as actionable as one reading "247", and this caps the count query.
  MAX_BADGE_COUNT = 99

  validates :kind, inclusion: { in: KINDS }
  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  def read?
    read_at.present?
  end

  # Idempotent: marking an already-read notification read again must not move
  # its timestamp, or "when did I see this" stops meaning anything.
  def mark_read!
    update!(read_at: Time.current) unless read?
  end

  # Capped so a user with thousands of unread rows doesn't turn every page load
  # into a full count. Postgres has no cheap exact count, but it has a very
  # cheap "are there at least N".
  def self.badge_count_for(user)
    unread.where(user: user).limit(MAX_BADGE_COUNT + 1).count
  end
end
