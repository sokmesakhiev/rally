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
        delete "events/:id",           to: "events#destroy"

        get "reports", to: "reports#index"

        # Queryable audit trail — see AdminAction, BaseController#log_admin_action.
        get "admin_actions", to: "admin_actions#index"
      end
    end
  end
end
