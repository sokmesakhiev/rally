# frozen_string_literal: true

# Validates POST /api/v1/events/:event_id/waitlist_entries. Shape only, same
# split as RegistrationCreateRequestSchema — the real invariant ("is this
# event/type actually full") lives on WaitlistEntry since it needs DB state
# this schema never sees.
class WaitlistEntryCreateRequestSchema < ApplicationRequestSchema
  params do
    optional(:event_type_ids).array(:string)
  end
end
