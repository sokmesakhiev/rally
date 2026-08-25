FactoryBot.define do
  factory :event_activity do
    association :event
    association :actor, factory: :user
    action { "update_event_details" }
    metadata { {} }
  end
end
