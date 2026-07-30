# frozen_string_literal: true

# Validates PATCH /api/v1/registrations/:id (organizer setting payment
# status). payment_status is checked against Registration::PAYMENT_STATUSES
# here for an early, specific error — the model's own
# `validates :payment_status, inclusion: { in: PAYMENT_STATUSES }` remains
# the real backstop (also runs for e.g. Registration#mark_paid_from_payment!,
# which never goes through this controller at all). amount_paid_cents has
# no model-level validation to mirror (Registration doesn't constrain it
# today), so this only checks it's an integer, not a range — inventing a
# >= 0 rule here that doesn't exist on the model would be a new constraint,
# not a moved one.
class RegistrationUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:registration).hash do
      optional(:payment_status).filled(:string, included_in?: Registration::PAYMENT_STATUSES)
      optional(:amount_paid_cents).maybe(:integer)
    end
  end
end
