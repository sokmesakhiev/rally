# frozen_string_literal: true

# Validates POST /api/v1/events/:event_id/registrations. Both fields are
# optional (an event with no types or no survey gets neither). Shape only
# — the real invariants (options belong to the question, required
# questions answered, capacity not exceeded) stay on RegistrationAnswer/
# Registration/RegistrationEventType, since they need the DB state
# (survey_question, event.capacity) this schema never sees.
class RegistrationCreateRequestSchema < ApplicationRequestSchema
  params do
    optional(:event_type_ids).array(:string)
    optional(:answers).array(:hash) do
      required(:survey_question_id).filled(:string)
      optional(:answer_text).maybe(:string)
      optional(:answer_options).array(:string)
    end
  end
end
