FactoryBot.define do
  factory :event_invitation do
    association :event
    association :invited_by, factory: :user
    email { Faker::Internet.unique.email }
    role { "manager" }
    # token and expires_at are set by EventInvitation's before_validation
    # on create — deliberately not stubbed here so the factory exercises
    # the same path the app does.

    trait :accepted do
      accepted_at { Time.current }
    end

    trait :revoked do
      revoked_at { Time.current }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
