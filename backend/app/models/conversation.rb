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

  # "Has this participant said something nobody on the team has read yet", as
  # one SQL predicate — an inbox is a list, and asking it per row in Ruby would
  # mean a query per conversation on every poll.
  #
  # The role is a bind parameter rather than interpolated. That isn't
  # superstition: an earlier version built this string with `#{...}` and fed it
  # to `select`, which Brakeman flagged as possible SQL injection. It was a
  # false positive — the only interpolated value was our own frozen constant —
  # but "safe because of where the value happens to come from" is exactly the
  # reasoning that stops being true after a refactor. Binding removes the
  # question.
  #
  # EXISTS rather than an IN subquery: `where.not(id: …)` compiles to NOT IN,
  # which a single NULL in the subquery turns into "no rows" silently.
  #
  # Deliberately *not* constrained to live threads. A thread can be resolved
  # with the participant's last message still unread, and an agent wants to see
  # that. `awaiting_staff` adds the live constraint for the inbox's "needs
  # action" sense.
  scope :with_unread_from_participant, lambda {
    where(
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

  # The inbox's "needs us" filter.
  scope :awaiting_staff, -> { live.with_unread_from_participant }

  # Which of these conversations have unread participant messages, as one
  # query for a whole page rather than one per row.
  #
  # Returns a Set of ids. The caller renders the flag from it, so the dot the
  # agent sees and the filter that put the row there are computed by the same
  # scope — if those ever drift, nobody reports it, the page just looks wrong.
  def self.unread_ids_among(conversations)
    ids = Array(conversations).map(&:id)
    return Set.new if ids.empty?

    with_unread_from_participant.where(id: ids).pluck(:id).to_set
  end

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
    unread_from(Message::STAFF, participant_last_read_at).exists?
  end

  def unread_for_staff?
    unread_from(Message::PARTICIPANT, staff_last_read_at).exists?
  end

  # What the chat launcher's badge shows. `exists?` above is the cheaper
  # question and is what the inbox asks; this one is for the one conversation
  # already being rendered.
  def unread_count_for_participant
    unread_from(Message::STAFF, participant_last_read_at).count
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

  # Strictly greater than, not >=: `mark_read_*!` stamps Time.current and
  # Conversations::PostMessage stamps the message's own created_at, so a
  # message at exactly the read instant is one the reader has seen — `>=`
  # would leave every sender's own reply flagged unread to themselves.
  def unread_from(role, read_at)
    scope = messages.where(sender_role: role)
    scope = scope.where("messages.created_at > ?", read_at) if read_at
    scope
  end
end
