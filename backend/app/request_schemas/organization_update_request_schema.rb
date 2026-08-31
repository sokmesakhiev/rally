# frozen_string_literal: true

# Validates PATCH /api/v1/organizations/:slug.
#
# Same field set as OrganizationRequestSchema with everything optional (a
# PATCH may carry one field), plus the PayWay credentials — which
# OrganizationsController#update accepts only from the owner, never an admin.
# See that action; the gate is there rather than here because dry-validation
# has no view of who is calling.
#
# :name stays optional-but-not-nil — an organization without a name would
# break the "Presented by" block and the public page it links to.
class OrganizationUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:organization).hash do
      optional(:name).filled(:string)
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
      # Owner-only — see OrganizationsController#update.
      optional(:payway_merchant_id).maybe(:string)
      optional(:payway_api_key).maybe(:string)
      optional(:payway_rsa_public_key).maybe(:string)
    end
  end
end
