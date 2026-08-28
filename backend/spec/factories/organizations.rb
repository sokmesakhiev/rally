FactoryBot.define do
  factory :organization do
    association :owner, factory: :user
    sequence(:name) { |n| "Phnom Penh Runners #{n}" }
    # slug is left blank on purpose — Organization#generate_slug fills it in,
    # so the factory exercises the real path rather than sidestepping it.
    description { "A running club based in Phnom Penh." }
    contact_email { "hello@example.com" }

    trait :verified do
      verified_at { Time.current }
    end

    trait :suspended do
      suspended_at { Time.current }
      suspension_reason { "Reported as fraudulent" }
    end

    trait :discarded do
      deleted_at { Time.current }
    end

    # Everything Ticket E (#334) requires before an event may be published.
    trait :publishable do
      logo_url { "https://example.com/logo.png" }
      description { "A running club based in Phnom Penh." }
      contact_email { "hello@example.com" }
    end

    trait :branded do
      logo_url { "https://example.com/logo.png" }
      banner_url { "https://example.com/banner.png" }
      brand_color { "#6366f1" }
      website { "https://example.com" }
    end
  end
end
