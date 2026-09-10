# frozen_string_literal: true

module Conversations
  # Pushes a newly created message to whoever is watching: the participant's
  # own stream, and the staff inbox.
  #
  # ## After commit, never inside the transaction
  #
  # `Conversations::PostMessage` writes inside `conversation.with_lock`, and
  # `Conversations::Resolve` writes inside its own. Broadcasting from in there
  # would publish a message id that subscribers can race to read *before* the
  # row is visible to other connections — and worse, a transaction that later
  # rolls back would have already told every client about a message that no
  # longer exists.
  #
  # `ActiveRecord.after_all_transactions_commit` is exactly the right tool:
  # it yields immediately when there's no open transaction, defers to the
  # outermost commit when there is, and never fires on rollback. That last
  # property is why this isn't just "call it after the block" — a caller that
  # wraps PostMessage in its own transaction would otherwise reintroduce the
  # bug from outside.
  #
  # ## Two audiences, two payloads
  #
  # Shapes come from Support::Serializers, the same module the REST endpoints
  # use. The client merges live and fetched messages into one list, so a
  # drifting shape shows up as messages that render differently depending on
  # how they arrived.
  #
  # The participant payload deliberately carries no sender name; the staff one
  # names the colleague. See that module.
  module Broadcast
    EVENT = "message.created"

    module_function

    def message_created(message)
      conversation = message.conversation

      ActiveRecord.after_all_transactions_commit do
        deliver(conversation, message)
      end
    end

    # The two audiences are independent, so their failures are too.
    #
    # A single method-level rescue would have let a failure on the participant
    # push — including a serializer error, since
    # `unread_count_for_participant` runs a query — abort before the staff
    # broadcast was even attempted, silently costing the inbox a live update
    # for a reason that had nothing to do with it.
    def deliver(conversation, message)
      publish(ChatChannel.stream_name_for(conversation.user_id), message) do
        {
          type: EVENT,
          conversation: ::Support::Serializers.participant_conversation(conversation),
          message: ::Support::Serializers.participant_message(message)
        }
      end

      publish(SupportInboxChannel::STREAM, message) do
        {
          type: EVENT,
          conversation: ::Support::Serializers.staff_conversation(conversation),
          message: ::Support::Serializers.staff_message(message)
        }
      end
    end

    # A failed broadcast must never fail the write that triggered it. The
    # message is already committed and REST will serve it on the next fetch —
    # the socket is an optimisation, so losing one push degrades to
    # "slightly stale" rather than losing data.
    #
    # The payload is built inside the rescue, not passed in, so a serializer
    # raising is contained the same way a dead cable connection is.
    def publish(stream, message)
      ActionCable.server.broadcast(stream, yield)
    rescue StandardError => e
      Rails.logger.warn(
        "[support chat] broadcast to #{stream} failed for message #{message.id}: #{e.class}: #{e.message}"
      )
      Sentry.capture_exception(e) if defined?(Sentry) && Sentry.initialized?
      nil
    end
  end
end
