# frozen_string_literal: true

# Validates POST /api/v1/events/:event_id/registrations. event_type_ids and
# answers are optional (an event with no types or no survey gets neither).
# Shape only — the real invariants (options belong to the question, required
# questions answered, capacity not exceeded) stay on RegistrationAnswer/
# Registration/RegistrationEventType, since they need the DB state
# (survey_question, event.capacity) this schema never sees.
#
# guest is also optional at the schema level (a signed-in request sends
# none of it) — RegistrationsController#create is what actually requires it
# once it knows there's no current_user, since that decision needs request
# state (the Authorization header) this schema never sees either. Both
# email and phone are optional here too — the controller requires at least
# one (phone-only registration is a first-class path, not a fallback; see
# Registrations::GuestCheckout). Email/phone format & uniqueness are left
# to GuestCheckout/User/Profile, same division of labor
# AuthSignupRequestSchema uses for signup.
class RegistrationCreateRequestSchema < ApplicationRequestSchema
  params do
    optional(:event_type_ids).array(:string)
    optional(:answers).array(:hash) do
      required(:survey_question_id).filled(:string)
      optional(:answer_text).maybe(:string)
      optional(:answer_options).array(:string)
    end
    optional(:guest).hash do
      required(:name).filled(:string)
      optional(:email).maybe(:string)
      optional(:phone).maybe(:string)
    end
  end
end
