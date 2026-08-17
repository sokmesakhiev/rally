FactoryBot.define do
  factory :admin_action do
    association :admin, factory: :user
    association :target, factory: :event
    action { "destroy_event" }
    metadata { {} }
  end
end
