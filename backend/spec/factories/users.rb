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
  end
end
