FactoryBot.define do
  factory :event_membership do
    association :event
    association :user
    role { "manager" }
    accepted_at { Time.current }

    trait :manager do
      role { "manager" }
    end

    trait :check_in do
      role { "check_in" }
    end

    trait :viewer do
      role { "viewer" }
    end
  end
end
