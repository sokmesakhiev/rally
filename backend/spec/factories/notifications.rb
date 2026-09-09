FactoryBot.define do
  factory :notification do
    association :user
    kind  { "payment_received" }
    title { "Payment received" }
    body  { "Your payment is confirmed." }
    url   { "/dashboard" }

    trait :read do
      read_at { 1.hour.ago }
    end
  end
end
