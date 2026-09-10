# frozen_string_literal: true

# Emails a participant about a staff reply they haven't read.
#
# Enqueued with `wait: DELAY` by Notifications::SupportNotifier the moment staff
# reply, and it re-checks on the way out. Chat is the primary channel; this is
# what stops "closed the tab" from turning a support conversation into a black
# hole.
#
# ## Why the check happens here rather than at enqueue time
#
# At enqueue time the participant has definitionally not read a message that was
# written a microsecond ago. The only useful question is whether they've read it
# *by the time the delay elapses*, which can only be asked now.
class SupportReplyFallbackEmailJob < ApplicationJob
  queue_as :default

  # Long enough that someone with the panel open and mid-conversation never
  # gets an email about a message they're actively reading, short enough to
  # still be useful for someone who walked away.
  DELAY = 3.minutes

  # Message rows are only ever deleted with the conversation, which only goes
  # with the account — so a missing one means there is nobody left to email.
  # Discard rather than retry into a permanent failure.
  discard_on ActiveRecord::RecordNotFound

  def perform(message_id)
    message = Message.find(message_id)
    conversation = message.conversation
    participant = conversation.user
    return if participant.nil?

    # Read it already: the whole point of the delay.
    return if read_since?(conversation, message)

    # A newer staff reply is queueing its own fallback, and two emails about
    # one conversation is worse than one slightly later. Let the last one win.
    return if superseded?(conversation, message)

    SupportMailer.reply_waiting(message).deliver_later
  end

  private

  def read_since?(conversation, message)
    read_at = conversation.participant_last_read_at
    read_at.present? && read_at >= message.created_at
  end

  def superseded?(conversation, message)
    conversation.messages
      .from_staff
      .where("messages.created_at > ?", message.created_at)
      .exists?
  end
end
