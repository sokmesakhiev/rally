FactoryBot.define do
  factory :event_report do
    association :event
    # Deliberately no reporter by default — anonymous is a first-class case
    # here, not an edge one, so the plain factory exercises it.
    reason { "violence" }
    details { "This looks like it's advertising a fight." }

    trait :from_reporter do
      association :reporter, factory: :user
    end

    trait :resolved do
      status { EventReport::DISMISSED }
      association :reviewed_by, factory: :user
      reviewed_at { 1.hour.ago }
    end
  end
end
