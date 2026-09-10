# frozen_string_literal: true

# One support thread: a participant on one side, Rally staff collectively on
# the other. See support-chat-tickets.md.
#
# Staff are not members of this record. Any admin can read and answer any
# conversation (Api::V1::Admin::BaseController's require_admin! is the whole
# gate), so there is no membership to model — only `assigned_admin`, a soft
# claim meaning "someone is looking at this", which anyone may take or release.
class Conversation < ApplicationRecord
  belongs_to :user
  belongs_to :assigned_admin, class_name: "User", optional: true
  has_many :messages, -> { order(created_at: :asc) }, dependent: :destroy, inverse_of: :conversation

  OPEN     = "open"      # needs an answer
  PENDING  = "pending"   # answered, waiting on the participant
  RESOLVED = "resolved"  # closed; the participant may start a new thread
  STATUSES = [ OPEN, PENDING, RESOLVED ].freeze

  # Anything not resolved holds the participant's one live slot.
  LIVE_STATUSES = (STATUSES - [ RESOLVED ]).freeze

  validates :status, inclusion: { in: STATUSES }
  validates :subject, length: { maximum: 200 }, allow_nil: true

  # Matches the partial unique index in
  # db/migrate/20260910010000_create_conversations_and_messages.rb. The
  # `conditions:` is what keeps the two in agreement: without it the model
  # would reject a second thread the database is perfectly willing to accept
  # once the first is resolved. Same pairing as Registration's kept-scoped
  # uniqueness.
  validates :user_id, uniqueness: {
    conditions: -> { where(status: LIVE_STATUSES) },
    message: "already has an open conversation"
  }, if: :live?

  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :resolved, -> { where(status: RESOLVED) }
  scope :newest_activity_first, -> { order(Arel.sql("last_message_at DESC NULLS LAST")) }
  scope :assigned_to, ->(admin) { where(assigned_admin: admin) }
  scope :unassigned, -> { where(assigned_admin_id: nil) }

  # The staff inbox's "needs us" filter, as one SQL predicate rather than a
  # per-row Ruby check — an inbox is a list, and doing this in Ruby would mean
  # a query per conversation on every poll.
  #
  # NOT EXISTS rather than `where.not(id: subquery)`: the latter compiles to
  # NOT IN, which a single NULL in the subquery turns into "no rows" silently.
  scope :awaiting_staff, lambda {
    where(status: LIVE_STATUSES).where(
      "EXISTS (
         SELECT 1 FROM messages
         WHERE messages.conversation_id = conversations.id
           AND messages.sender_role = :participant
           AND (conversations.staff_last_read_at IS NULL
                OR messages.created_at > conversations.staff_last_read_at)
       )",
      participant: Message::PARTICIPANT
    )
  }

  def live?
    status != RESOLVED
  end

  def resolved?
    status == RESOLVED
  end

  # "Unread" always means unread *from the other side*. Comparing a read stamp
  # against `last_message_at` would be cheaper but wrong: your own reply is the
  # newest message in the thread, and it must not light up your own badge.
  def unread_for_participant?
    unread_from?(Message::STAFF, participant_last_read_at)
  end

  def unread_for_staff?
    unread_from?(Message::PARTICIPANT, staff_last_read_at)
  end

  def mark_read_for_participant!
    update!(participant_last_read_at: Time.current)
  end

  def mark_read_for_staff!
    update!(staff_last_read_at: Time.current)
  end

  def resolve!
    update!(status: RESOLVED)
  end

  private

  # Strictly greater than, not >=: `mark_read_*!` stamps Time.current, and a
  # message written in that same instant should count as seen rather than
  # immediately re-flagging the thread as unread.
  def unread_from?(role, read_at)
    scope = messages.where(sender_role: role)
    scope = scope.where("messages.created_at > ?", read_at) if read_at
    scope.exists?
  end
end
