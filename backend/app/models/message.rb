# frozen_string_literal: true

# One message in a support conversation.
class Message < ApplicationRecord
  PARTICIPANT = "participant"
  STAFF       = "staff"
  SYSTEM      = "system"
  SENDER_ROLES = [ PARTICIPANT, STAFF, SYSTEM ].freeze

  # Mirrors the messages_body_length CHECK constraint. Generous enough that
  # nobody pastes a log excerpt and loses it, small enough that a single row
  # can't be used to push megabytes into the thread.
  MAX_BODY_LENGTH = 5_000

  # `touch: :last_message_at` is what keeps the staff inbox sortable without a
  # correlated subquery — it bumps that column (and updated_at) on the parent
  # whenever a message is created, updated or destroyed.
  belongs_to :conversation, touch: :last_message_at, inverse_of: :messages

  # Optional because the database nullifies this when an account is destroyed,
  # so a departed staff member's replies survive inside a participant's thread.
  # `sender_role` is what still identifies which side sent it.
  belongs_to :sender, class_name: "User", optional: true

  before_validation :assign_sender_role, on: :create

  validates :sender_role, inclusion: { in: SENDER_ROLES }
  validates :body, presence: true, length: { maximum: MAX_BODY_LENGTH }
  validate :sender_present_unless_system, on: :create

  scope :oldest_first, -> { order(created_at: :asc) }
  scope :from_participant, -> { where(sender_role: PARTICIPANT) }
  scope :from_staff, -> { where(sender_role: STAFF) }
  # The reconnect catch-up: everything the client hasn't seen. A WebSocket is
  # never a durable transport — every deploy severs every connection — so this
  # is the query that makes the socket an optimisation rather than the source
  # of truth.
  # Compares the (created_at, id) pair rather than created_at alone: two
  # messages can share a timestamp, and a plain `>` would then drop one of them
  # forever while `>=` would replay it. The pair is unique by construction, so
  # the cursor lands between rows exactly.
  #
  # An unrecognised id falls back to the whole thread rather than an empty
  # result — the client asking is one whose cursor we can't place, and a full
  # resync is the recoverable answer where "nothing" looks like data loss.
  scope :after_id, lambda { |id|
    next all if id.blank?

    cursor = Message.where(id: id).pick(:created_at, :id)
    next all if cursor.nil?

    where("(messages.created_at, messages.id) > (?, ?)", *cursor)
  }

  # Scrolling back through history — the mirror of after_id, and the reason
  # `has_more` on a first page is actionable rather than merely informative. A
  # thread longer than one page would otherwise have a beginning the
  # participant could never reach.
  #
  # Note the fallback differs from after_id's on purpose. There, an unplaceable
  # cursor means a client that may have lost messages, so a full resync is the
  # safe answer. Here it would mean silently serving the newest page again as
  # though it were older history — an infinite scroll that never advances — so
  # an unknown cursor returns nothing instead.
  scope :before_id, lambda { |id|
    next none if id.blank?

    cursor = Message.where(id: id).pick(:created_at, :id)
    next none if cursor.nil?

    where("(messages.created_at, messages.id) < (?, ?)", *cursor)
  }

  def from_participant?
    sender_role == PARTICIPANT
  end

  def from_staff?
    sender_role == STAFF
  end

  def system?
    sender_role == SYSTEM
  end

  # True once the sender's account has been destroyed — the row survives, the
  # person doesn't. Renders as "deleted account" rather than as nobody.
  def orphaned_sender?
    sender_id.nil? && !system?
  end

  private

  # Derived from *position in the thread*, not from `users.admin`.
  #
  # An admin can perfectly well open their own support conversation, and in
  # that thread they are the participant. Keying off the admin flag would
  # label their own messages "staff" and put them on the wrong side of their
  # own conversation. "Is this the person the thread belongs to?" has no such
  # ambiguity.
  #
  # Only ever assigned on create, and never recomputed: this is a snapshot of
  # who sent it at the time, and revoking an admin flag later must not rewrite
  # history. Callers may set it explicitly (SYSTEM) and are left alone.
  def assign_sender_role
    return if sender_role.present?
    return if conversation.nil?

    self.sender_role = sender_id == conversation.user_id ? PARTICIPANT : STAFF
  end

  def sender_present_unless_system
    return if system? || sender_id.present?

    errors.add(:sender, "must be present unless the message is from the system")
  end
end
