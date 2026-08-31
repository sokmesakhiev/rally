FactoryBot.define do
  factory :organization_membership do
    association :organization
    association :user
    role { "admin" }

    trait :admin do
      role { "admin" }
    end

    trait :member do
      role { "member" }
    end
  end
end
