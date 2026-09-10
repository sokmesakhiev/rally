# frozen_string_literal: true

# Validates POST /api/v1/support/conversation.
#
# Subject is optional and usually absent — the first message is normally
# context enough, and demanding a subject line from someone who wants help is
# friction at the wrong moment.
class SupportConversationCreateRequestSchema < ApplicationRequestSchema
  MAX_SUBJECT_LENGTH = 200

  params do
    optional(:subject).maybe(:string)
  end

  rule(:subject) do
    next if value.blank?

    key.failure("is too long (maximum is #{MAX_SUBJECT_LENGTH} characters)") if
      value.to_s.strip.length > MAX_SUBJECT_LENGTH
  end
end
