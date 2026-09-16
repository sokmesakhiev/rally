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
#
# bib_number is `maybe` rather than `filled` because clearing a bib is a real
# operation — sending null must reach the model, where `normalizes` turns it
# (and a blank string) into NULL so the partial unique index treats the row as
# unassigned. Uniqueness is the model's and the database's job, not this
# schema's: it needs the event scope, which isn't in the payload.
class RegistrationUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:registration).hash do
      optional(:payment_status).filled(:string, included_in?: Registration::PAYMENT_STATUSES)
      optional(:amount_paid_cents).maybe(:integer)
      optional(:bib_number).maybe(:string, max_size?: 32)
    end
  end
end
