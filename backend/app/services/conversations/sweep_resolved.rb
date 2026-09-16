# frozen_string_literal: true

module Conversations
  # Destroys support threads that have been resolved longer than
  # Conversation::RETENTION_PERIOD.
  #
  # This is the enforcement half of a published promise — the privacy policy
  # states the number, so a retention policy that exists only in prose is worse
  # than none at all. `Conversation::RETENTION_PERIOD` is the single source for
  # both.
  #
  # Only *resolved* threads are ever in scope. A thread nobody has closed is
  # still someone's open question however old it is, and deleting it would
  # answer them by making the question disappear.
  class SweepResolved
    Result = Struct.new(:conversations, :messages, keyword_init: true)

    # Batch size for one run. Destroying cascades to messages, so a very large
    # first sweep (the backfill means every historically-resolved thread
    # becomes eligible at once) would otherwise be a single long transaction
    # on the worker. Daily + capped drains it over days; in steady state the
    # cap is never reached.
    MAX_PER_RUN = 500

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now: Time.current)
      @now = now
    end

    def call
      conversations = 0
      messages = 0

      Conversation.purgeable(@now).limit(MAX_PER_RUN).each do |conversation|
        # Counted before the destroy, since afterwards there is nothing to
        # count. The figure is what makes the log line worth having: "purged 3
        # threads" and "purged 3 threads and 412 messages" answer different
        # questions when someone is checking the policy is actually running.
        message_count = conversation.messages.count

        if destroy(conversation)
          conversations += 1
          messages += message_count
        end
      end

      Result.new(conversations: conversations, messages: messages)
    end

    private

    # Per-thread rather than a bulk `destroy_all`, so one undestroyable row
    # can't stop the rest of the sweep. Retention that silently stops running
    # because of a single bad record is the failure mode worth designing
    # against — nobody notices data *not* being deleted.
    def destroy(conversation)
      conversation.destroy!
      true
    rescue StandardError => e
      Rails.logger.warn(
        "[retention] could not purge conversation #{conversation.id}: #{e.class}: #{e.message}"
      )
      Sentry.capture_exception(e) if defined?(Sentry) && Sentry.initialized?
      false
    end
  end
end
