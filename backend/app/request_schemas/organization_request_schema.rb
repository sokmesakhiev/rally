# frozen_string_literal: true

# Validates POST /api/v1/organizations (OrganizationsController#create).
#
# Deliberately mirrors — not duplicates — Organization's own validations, the
# same split EventRequestSchema documents: this catches bad shapes early and
# cheaply, while format checks (URL_FORMAT, contact_email, name length) still
# live on the model, so the controller keeps rescuing RecordInvalid.
#
# Two fields are absent on purpose:
#   * slug is generated from the name and immutable afterwards (see
#     Organization#generate_slug) — accepting one here would let a caller
#     squat a URL that then can never be corrected.
#   * verified_at / suspended_at are moderation state, set only through the
#     admin namespace. Accepting them would let any organizer mark themselves
#     verified, which is the entire trust signal the badge carries.
class OrganizationRequestSchema < ApplicationRequestSchema
  params do
    required(:organization).hash do
      required(:name).filled(:string)
      optional(:description).maybe(:string)
      optional(:logo_url).maybe(:string)
      optional(:banner_url).maybe(:string)
      optional(:brand_color).maybe(:string)
      optional(:website).maybe(:string)
      optional(:contact_email).maybe(:string)
      optional(:contact_phone).maybe(:string)
      optional(:facebook_url).maybe(:string)
      optional(:instagram_url).maybe(:string)
      optional(:telegram_url).maybe(:string)
    end
  end
end
