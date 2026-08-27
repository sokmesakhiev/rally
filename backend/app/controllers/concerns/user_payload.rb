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
        # True for a phone-only guest checkout — see
        # Registrations::GuestCheckout — meaning `email` above is a
        # placeholder, not something the frontend should ever display or
        # rely on being reachable. Drives the "add your real email" nudge
        # on the account settings page.
        email_auto_generated: user.email_auto_generated?,
        phone: profile&.phone,
        display_name: profile&.display_name,
        avatar_url: profile&.avatar_url,
        email_verified: user.email_verified?,
        # Admin-granted organizer verification, NOT the self-service email
        # check above — this is what unlocks creating paid events. Drives the
        # frontend's paid-event gating (a UX affordance only; the real check
        # is EventsController#reject_unverified_paid_event!). See
        # User#verified?.
        verified: user.verified?,
        # Drives whether the frontend shows the admin nav link. Not a
        # security boundary — every admin endpoint checks server-side via
        # require_admin! regardless of what the client believes.
        admin: user.admin?,
        # Null means this account has never accepted the Terms of Service —
        # true for a brand-new Google sign-in (see
        # User.find_or_create_from_google!) since that flow never shows a
        # checkbox. Drives the frontend's one-time acceptance interstitial
        # (see event-freeze-and-terms-tickets.md's Ticket H) — not a security
        # boundary, just a UX prompt; nothing server-side is blocked on it.
        terms_accepted_at: user.terms_accepted_at,
        created_at: user.created_at
      }
    }
    payload[:token] = token if token
    payload
  end
end
