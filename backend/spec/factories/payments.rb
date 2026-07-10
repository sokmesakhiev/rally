FactoryBot.define do
  factory :payment do
    association :registration
    provider     { "aba_payway" }
    sequence(:tran_id) { |n| "rlytest#{n}" }
    status       { "pending" }
    amount_cents { 2500 }
    currency     { "usd" }
    expires_at   { 15.minutes.from_now }

    trait :approved do
      status  { "approved" }
      paid_at { Time.current }
    end

    trait :expired do
      expires_at { 1.minute.ago }
    end
  end
end
