Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Active Storage routes (for serving uploaded files)
  direct :rails_blob do |blob, options|
    route_for(:rails_service_blob, blob.signed_id, blob.filename, options)
  end

  namespace :api do
    namespace :v1 do
      # Auth
      post   "auth/signup", to: "auth#signup"
      post   "auth/signin", to: "auth#signin"
      post   "auth/google", to: "auth#google"
      get    "auth/me",     to: "auth#me"
      patch  "auth/password", to: "auth#change_password"
      patch  "auth/email",    to: "auth#change_email"
      delete "auth/account",  to: "auth#delete_account"
      # Google sign-in's terms-of-service gap — see auth#accept_terms.
      post   "auth/accept_terms", to: "auth#accept_terms"

      # Password resets
      post  "password_resets",        to: "password_resets#create"
      patch "password_resets/:token", to: "password_resets#update"

      # Email verification
      post "email_verifications",        to: "email_verifications#create"
      get  "email_verifications/:token", to: "email_verifications#show"

      # Events
      get    "events",               to: "events#index"
      get    "events/my",            to: "events#my_events"
      post   "events",               to: "events#create"
      get    "events/:id",           to: "events#show"
      patch  "events/:id",           to: "events#update"
      delete "events/:id",           to: "events#destroy"
      post   "events/:id/unpublish", to: "events#unpublish"
      get    "events/:id/activity",  to: "events#activity"

      # Pricing plans (organizer pays to publish — see Event::PLANS)
      get  "event_plans",                    to: "event_plans#index"
      post "events/:event_id/plan_payments", to: "event_plan_payments#create"
      get  "plan_payments/:id",              to: "event_plan_payments#show"

      # Registrations
      get    "registrations",                  to: "registrations#index"
      post   "events/:event_id/registrations", to: "registrations#create"
      get    "events/:event_id/registrations", to: "registrations#event_registrations"
      get    "events/:event_id/registrations/export", to: "registrations#export"
      patch  "registrations/:id",              to: "registrations#update"
      delete "registrations/:id",              to: "registrations#destroy"

      # Check-in / attendance — organizer scans the attendee's ticket QR
      # (which just encodes the registration id) or taps them in manually.
      post   "registrations/:id/check_in", to: "registrations#check_in"
      delete "registrations/:id/check_in", to: "registrations#undo_check_in"

      # In-app notifications — the header bell. #index is polled by every open
      # tab, so it stays a single indexed query. See NotificationsController.
      get  "notifications",           to: "notifications#index"
      post "notifications/read_all",  to: "notifications#read_all"
      post "notifications/:id/read",  to: "notifications#read"

      # Support chat, participant side. The staff side lives under the admin
      # namespace below/elsewhere — see Api::V1::Support::BaseController.
      #
      # No :id anywhere on purpose: a participant has at most one live thread
      # (enforced by a partial unique index), so "which conversation" is never
      # theirs to choose and there's nothing to authorize per-record.
      scope :support do
        get  "conversation", to: "support/conversations#show"
        post "conversation", to: "support/conversations#create"
        post "read",         to: "support/conversations#read"
        # ?after=<message id> is the reconnect catch-up — see
        # Api::V1::Support::MessagesController and Message.after_id.
        get  "messages",     to: "support/messages#index"
        post "messages",     to: "support/messages#create"
      end

      # WebSocket auth. Browsers can't set headers on a WebSocket, and the JWT
      # is valid for 30 days — far too long to put in a URL that lands in ALB
      # access logs and browser history. Clients POST here (with the normal
      # Bearer token) for a single-use, 30-second ticket instead, then connect
      # to /cable?ticket=... See Cable::Ticket.
      post "cable/ticket", to: "cable_tickets#create"

      # Web push. #vapid_public_key is unauthenticated on purpose — it returns
      # a public key the browser needs before it can subscribe at all.
      #
      # Unsubscribing is a POST rather than a DELETE: the endpoint is a long,
      # opaque, vendor-controlled URL that belongs in a body (not a path, and
      # not a query string where it would reach every access log), and bodies
      # on DELETE aren't reliably parsed end to end. See
      # PushSubscriptionsController#unsubscribe.
      get   "push/vapid_public_key", to: "push_subscriptions#vapid_public_key"
      post  "push/subscriptions",    to: "push_subscriptions#create"
      post  "push/unsubscribe",      to: "push_subscriptions#unsubscribe"

      # Results (finish times) — optional per event; race-style events use
      # it, e.g. a social gathering never gets one. Set one at a time or in
      # bulk via CSV.
      patch "registrations/:id/result",        to: "results#update"
      post  "events/:event_id/results/import", to: "results#import"
      get   "events/:event_id/results",        to: "results#index"

      # Waitlists — join when an event/type is full, promoted automatically
      # (Waitlists::PromoteNext) when a registration is cancelled/removed.
      get    "waitlist_entries",                  to: "waitlist_entries#index"
      post   "events/:event_id/waitlist_entries", to: "waitlist_entries#create"
      get    "events/:event_id/waitlist_entries", to: "waitlist_entries#event_waitlist"
      delete "waitlist_entries/:id",               to: "waitlist_entries#destroy"

      # Payments (ABA PayWay KHQR)
      post "registrations/:registration_id/payments", to: "payments#create"
      get  "payments/:id",                             to: "payments#show"

      # Refunds (organizer or admin — see Refunds::IssueRefund)
      get  "payments/:payment_id/refunds", to: "refunds#index"
      post "payments/:payment_id/refunds", to: "refunds#create"

      # Payment provider webhooks (no user auth — verified server-to-server)
      post "webhooks/aba_payway", to: "webhooks/aba_payway#create"

      # Profile
      get   "profile", to: "profiles#show"
      patch "profile", to: "profiles#update"

      # Surveys (organizer manages their surveys)
      get    "surveys",     to: "surveys#index"
      post   "surveys",     to: "surveys#create"
      get    "surveys/:id", to: "surveys#show"
      patch  "surveys/:id", to: "surveys#update"
      delete "surveys/:id", to: "surveys#destroy"

      # Survey responses (organizer reads participant answers)
      get "events/:event_id/survey_responses", to: "survey_responses#index"

      # Event membership invitations (owner-only send/list/revoke — see
      # EventInvitation/EventMembership).
      get    "events/:event_id/invitations",     to: "event_invitations#index"
      post   "events/:event_id/invitations",     to: "event_invitations#create"
      delete "events/:event_id/invitations/:id", to: "event_invitations#destroy"

      # Accepting an event invitation (issue #276) — the recipient's side,
      # keyed by token rather than event_id/id.
      get  "invitations/:token",        to: "invitations#show"
      post "invitations/:token/accept", to: "invitations#accept"

      # Managing an event's already-accepted team (issue #280) — see
      # EventMembership. Listing is open to any member; role changes and
      # removing someone else are owner-only, but any member may remove
      # themselves (leave).
      get    "events/:event_id/members",     to: "event_members#index"
      patch  "events/:event_id/members/:id", to: "event_members#update"
      delete "events/:event_id/members/:id", to: "event_members#destroy"

      # The PUBLIC organizer page (Ticket F, #335) — no auth, world-readable.
      # Deliberately its own resource rather than an action on organizations
      # below: that surface is authenticated management and its payload
      # carries PayWay status and the owner's identity. Keeping the two apart
      # in the routes is the first line of defence against a private field
      # ending up in a public response.
      get "organizers/:slug", to: "organizers#show"

      # Organizations — the identity an event is presented under. See
      # organization-identity-tickets.md's Ticket D (#333). Addressed by slug
      # (Organization#to_param), which is immutable once generated, so these
      # URLs stay valid for as long as the organization does.
      #
      # #index lists only the organizations the caller owns or administers —
      # it's the org switcher's data source, not a public directory. The
      # public-facing page is Ticket F (#335).
      get    "organizations",       to: "organizations#index"
      post   "organizations",       to: "organizations#create"
      get    "organizations/:slug", to: "organizations#show"
      patch  "organizations/:slug", to: "organizations#update"
      delete "organizations/:slug", to: "organizations#destroy"
      post   "organizations/:slug/transfer_ownership", to: "organizations#transfer_ownership"

      # An organization's team. Mirrors events/:event_id/members: listing is
      # open to any member, changes are owner/admin, and anyone may remove
      # themselves.
      get    "organizations/:slug/members",     to: "organization_members#index"
      post   "organizations/:slug/members",     to: "organization_members#create"
      patch  "organizations/:slug/members/:id", to: "organization_members#update"
      delete "organizations/:slug/members/:id", to: "organization_members#destroy"

      # File uploads
      post "uploads", to: "uploads#create"

      # ── Admin / moderation ──────────────────────────────────────────────
      # Requires an authenticated, non-suspended user with `admin` set (see
      # Api::V1::Admin::BaseController). Non-admins get 404, not 403, so this
      # surface doesn't advertise itself. Admin is granted from the console
      # only — there is deliberately no promote-to-admin endpoint.
      namespace :admin do
        get  "users",              to: "users#index"
        post "users/:id/suspend",   to: "users#suspend"
        post "users/:id/unsuspend", to: "users#unsuspend"
        # Organizer verification — gates creating paid events. Distinct from
        # the self-service email verification flow (see User#verified?).
        post "users/:id/verify",    to: "users#verify"
        post "users/:id/unverify",  to: "users#unverify"

        get    "events",              to: "events#index"
        post   "events/:id/unpublish", to: "events#unpublish"
        # Suspend: the moderation lever stronger than unpublish — not
        # reversible by the organizer at all (see EventAuthorization's
        # suspended lockdown and Event#suspend!/#unsuspend!). Named/shaped
        # to match users/:id/suspend above, since it's the same concept
        # applied to an event. See event-freeze-and-terms-tickets.md's
        # Ticket B.
        post   "events/:id/suspend",    to: "events#suspend"
        post   "events/:id/unsuspend",  to: "events#unsuspend"
        delete "events/:id",           to: "events#destroy"

        # Organization moderation (Ticket J, #339). Suspending an
        # organization takes down every event it presents, because
        # Event#suspended? derives from it — and unsuspending restores them
        # automatically, since nothing was written to them.
        get  "organizations",              to: "organizations#index"
        post "organizations/:id/suspend",   to: "organizations#suspend"
        post "organizations/:id/unsuspend", to: "organizations#unsuspend"
        # Gates creating paid events (Ticket I, #338) — the organization-level
        # counterpart of users/:id/verify above, which stays in place for one
        # release while the gate moves across.
        post "organizations/:id/verify",   to: "organizations#verify"
        post "organizations/:id/unverify", to: "organizations#unverify"

        get "reports", to: "reports#index"

        # Queryable audit trail — see AdminAction, BaseController#log_admin_action.
        get "admin_actions", to: "admin_actions#index"
      end
    end
  end
end
