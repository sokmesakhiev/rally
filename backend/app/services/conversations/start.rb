# frozen_string_literal: true

module Conversations
  # Returns the participant's live support thread, creating one if they don't
  # have it. Idempotent by design: the chat widget calls this every time the
  # panel opens, and opening a panel twice must not produce two threads.
  module Start
    Result = Data.define(:conversation, :created)

    module_function

    # The rescue is the whole reason this isn't a one-line `find_or_create_by`.
    #
    # Between the SELECT and the INSERT there is a window, and the widget makes
    # it a realistic one rather than a theoretical one: a double-tap on the
    # launcher, or a client retrying a request whose response was lost, both
    # fire two of these concurrently. The partial unique index catches the
    # second, and the correct response to losing that race is to hand back the
    # thread the winner just made — the caller asked for "my conversation",
    # and there now is one.
    #
    # Both exception types have to be caught, because which one fires depends
    # on how the race lands. The model's uniqueness validation does its own
    # SELECT, so the usual loser gets ActiveRecord::RecordInvalid; a caller
    # unlucky enough to have that SELECT run before the winner's INSERT commits
    # gets past validation and is stopped by the index itself, as
    # ActiveRecord::RecordNotUnique. Handling only one leaves a rare 500 that
    # is essentially impossible to reproduce on demand.
    def call(user:, subject: nil)
      existing = live_for(user)
      return Result.new(conversation: existing, created: false) if existing

      # Wrapped in its own savepoint (`requires_new: true`) rather than left
      # bare, because of what a unique violation does to an *enclosing*
      # transaction. Once Postgres raises, that transaction is aborted, and
      # every subsequent statement in it — including this method's own
      # `live_for(user)` lookup in the rescue — fails with
      # PG::InFailedSqlTransaction. The race handling below would then blow up
      # instead of recovering, and only when called from inside a transaction.
      #
      # No current caller does that, but Ticket C and D's callers plausibly
      # will, and this is the same trap Notifications::RegistrationNotifier hit
      # (see PR #410). A savepoint scopes the rollback to just this INSERT.
      conversation = ::Conversation.transaction(requires_new: true) do
        ::Conversation.create!(user: user, subject: subject, status: ::Conversation::OPEN)
      end
      Result.new(conversation: conversation, created: true)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise unless lost_the_race?(e)

      # Re-raise if the row still isn't there: that would mean the violation
      # came from something other than the one-live-thread rule, and swallowing
      # it would turn an unrelated failure into a confusing nil.
      raced = live_for(user)
      raise if raced.nil?

      Result.new(conversation: raced, created: false)
    end

    def lost_the_race?(error)
      return true if error.is_a?(ActiveRecord::RecordNotUnique)

      # A RecordInvalid for any other reason — an over-long subject, say — is a
      # real error about this caller's own input and must not be swallowed.
      error.record.errors.of_kind?(:user_id, :taken)
    end

    def live_for(user)
      user.conversations.live.first
    end
  end
end
