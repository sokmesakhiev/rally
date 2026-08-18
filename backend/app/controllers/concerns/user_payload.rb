# frozen_string_literal: true

# Shared shape for "here's a signed-in session" responses — { user: {...},
# token: "..." }. Used by Api::V1::AuthController (signup/signin/google/me)
# and Api::V1::RegistrationsController (guest checkout — see
# Registrations::GuestCheckout — silently hands a brand-new guest the same
# kind of session so the rest of the registration/payment flow can treat
# them exactly like a normal signed-in user).
#
# The :user sub-hash's shape matches the frontend's ApiUser interface
# (src/lib/api-client.ts) — keep both in sync.
module UserPayload
  extend ActiveSupport::Concern

  def user_payload(user, token)
    profile = user.profile
    payload = {
      user: {
        id: user.id,
        email: user.email,
        display_name: profile&.display_name,
        avatar_url: profile&.avatar_url,
        email_verified: user.email_verified?,
        # Drives whether the frontend shows the admin nav link. Not a
        # security boundary — every admin endpoint checks server-side via
        # require_admin! regardless of what the client believes.
        admin: user.admin?,
        created_at: user.created_at
      }
    }
    payload[:token] = token if token
    payload
  end
end
