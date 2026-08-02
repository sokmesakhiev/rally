FactoryBot.define do
  factory :waitlist_entry do
    association :event
    association :user

    event_type_ids { [] }
    status { "waiting" }

    trait :promoted do
      status { "promoted" }
    end

    trait :cancelled do
      status { "cancelled" }
    end
  end
end
