# frozen_string_literal: true

# Enforces the support-chat retention window (see Conversations::SweepResolved
# and Conversation::RETENTION_PERIOD).
#
# Daily rather than hourly: the window is twelve months, so the difference
# between purging a thread today and purging it in twenty-three hours is not
# worth twenty-four runs a day on a worker that also renders certificates.
class SweepResolvedConversationsJob < ApplicationJob
  queue_as :default

  def perform
    result = Conversations::SweepResolved.call
    return if result.conversations.zero?

    # Logged at info and in the same structured shape as the other sweeps, so
    # "is the retention policy actually running?" is answerable from the log
    # group rather than by querying production.
    Rails.logger.info(
      {
        event: "retention.conversations_purged",
        conversations: result.conversations,
        messages: result.messages
      }.to_json
    )
  end
end
