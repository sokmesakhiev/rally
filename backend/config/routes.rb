Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Active Storage routes (for serving uploaded files)
  direct :rails_blob do |blob, options|
    route_for(:rails_service_blob, blob.signed_id, blob.filename, options)
  end

  namespace :api do
    namespace :v1 do
      # Auth
      post "auth/signup", to: "auth#signup"
      post "auth/signin", to: "auth#signin"
      post "auth/google", to: "auth#google"
      get  "auth/me",     to: "auth#me"

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

      # Pricing plans (organizer pays to publish — see Event::PLANS)
      get  "event_plans",                    to: "event_plans#index"
      post "events/:event_id/plan_payments", to: "event_plan_payments#create"
      get  "plan_payments/:id",              to: "event_plan_payments#show"

      # Registrations
      get    "registrations",                  to: "registrations#index"
      post   "events/:event_id/registrations", to: "registrations#create"
      get    "events/:event_id/registrations", to: "registrations#event_registrations"
      patch  "registrations/:id",              to: "registrations#update"
      delete "registrations/:id",              to: "registrations#destroy"

      # Payments (ABA PayWay KHQR)
      post "registrations/:registration_id/payments", to: "payments#create"
      get  "payments/:id",                             to: "payments#show"

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

      # File uploads
      post "uploads", to: "uploads#create"
    end
  end
end
