# frozen_string_literal: true

# Validates PATCH /api/v1/profile. All fields optional (partial update —
# see EventUpdateRequestSchema's class comment for why absent-vs-null
# matters here). Profile's own cross-field rule ("payway_api_key required
# if payway_merchant_id present, and vice versa" — see
# app/models/profile.rb) is intentionally NOT duplicated here: it's a
# business invariant that must hold regardless of which code path writes
# to Profile, so it stays model-only.
class ProfileUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:profile).hash do
      optional(:display_name).maybe(:string)
      optional(:avatar_url).maybe(:string)
      optional(:phone).maybe(:string)
      # TRANSITIONAL, remove with Ticket G (#336). These no longer land on
      # Profile at all — ProfilesController proxies them to the caller's
      # organization (see #331), because the payment-settings form still posts
      # here until #336 moves that UI. Delete these three keys, and the
      # proxying in ProfilesController, together.
      optional(:payway_merchant_id).maybe(:string)
      optional(:payway_api_key).maybe(:string)
      optional(:payway_rsa_public_key).maybe(:string)
      optional(:notify_payment_received).filled(:bool)
      optional(:notify_refund_issued).filled(:bool)
      optional(:notify_promoted_from_waitlist).filled(:bool)
      optional(:notify_event_details_changed).filled(:bool)
    end
  end
end
