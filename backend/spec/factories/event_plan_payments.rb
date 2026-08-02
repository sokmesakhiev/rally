FactoryBot.define do
  factory :event_plan_payment do
    association :event
    user { event.creator }
    plan { "small" }
    provider { "aba_payway" }
    sequence(:tran_id) { |n| "plntest#{n}" }
    status { "pending" }
    amount_cents { 10_000 }
    currency { "usd" }
    expires_at { 15.minutes.from_now }

    trait :paid do
      status  { "paid" }
      paid_at { Time.current }
    end
  end
end
