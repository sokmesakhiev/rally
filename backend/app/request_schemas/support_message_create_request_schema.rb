# frozen_string_literal: true

# Validates POST /api/v1/support/messages.
#
# The length cap is duplicated from Message::MAX_BODY_LENGTH (and from the
# messages_body_length CHECK constraint) on purpose. This is the only one of
# the three that produces a message a person can act on — the model validation
# is the safety net for non-HTTP callers, and the constraint is what still
# holds when something writes around Active Record entirely.
class SupportMessageCreateRequestSchema < ApplicationRequestSchema
  params do
    required(:body).filled(:string)
  end

  rule(:body) do
    trimmed = value.to_s.strip

    if trimmed.empty?
      # `filled(:string)` already rejects "" but not "   ", and a thread full
      # of blank bubbles is a support agent's problem, not the sender's.
      key.failure("can't be blank")
    elsif trimmed.length > Message::MAX_BODY_LENGTH
      key.failure("is too long (maximum is #{Message::MAX_BODY_LENGTH} characters)")
    end
  end
end
