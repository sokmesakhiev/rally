FactoryBot.define do
  factory :user do
    email { Faker::Internet.unique.email }
    password { "password123" }
    password_confirmation { password }

    # Automatically builds associated profile (User#after_create calls create_profile!)
    # so no explicit trait needed for basic cases.

    trait :with_display_name do
      after(:create) do |user|
        user.profile.update!(display_name: Faker::Name.name)
      end
    end

    # Admin-granted organizer verification (User#verified?) — what unlocks
    # creating paid events. Unrelated to email verification.
    trait :verified do
      verified_at { Time.current }
    end

    # Admin moderation (User#suspend!). Set directly rather than by calling
    # #suspend! so the factory doesn't fire that method's side effects.
    trait :suspended do
      suspended_at { Time.current }
      suspension_reason { "Reported" }
    end
  end
end
