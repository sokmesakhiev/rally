# frozen_string_literal: true

module Conversations
  # Closes a support thread and leaves a note saying so.
  #
  # The system message matters more than it looks: resolving frees the
  # participant's one live slot, so the next thing they send starts a *new*
  # conversation rather than continuing this one. Without a visible marker,
  # that reads to them as their history vanishing. This is the first thing in
  # the app to write a `system` message — the role existed in the schema from
  # Ticket A with nothing generating it.
  module Resolve
    RESOLVED_NOTICE = "This conversation was marked resolved. Send a new message any time to reopen a thread."

    module_function

    # Idempotent: resolving an already-resolved thread does nothing and adds no
    # second notice, so a double-clicked button in the console is harmless.
    #
    # Ordering matters. The status has to be written *before* the notice,
    # because Conversations::PostMessage would otherwise read a still-live
    # thread and flip it to "pending" — putting a conversation the agent just
    # closed back in front of them. Writing the status first means
    # `status_change` sees a resolved thread and leaves it alone.
    def call(conversation:)
      return false if conversation.resolved?

      notice = nil

      # `next`, not `break`: exiting a transaction block with break/return has
      # meant different things across Rails versions (commit in one, rollback
      # in another). `next` is block-local and unambiguous.
      conversation.with_lock do
        next if conversation.resolved?

        conversation.update!(status: ::Conversation::RESOLVED)
        notice = conversation.messages.create!(
          sender: nil,
          sender_role: ::Message::SYSTEM,
          body: RESOLVED_NOTICE
        )
      end

      # The notice goes out over the socket like any other message, which is
      # what tells an open chat panel the thread just closed — the payload
      # carries the conversation with its new status alongside it.
      Broadcast.message_created(notice) if notice

      notice.present?
    end
  end
end
