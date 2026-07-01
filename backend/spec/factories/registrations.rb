FactoryBot.define do
  factory :registration do
    association :event
    association :user

    status         { "confirmed" }
    payment_status { "unpaid" }
    amount_paid_cents { 0 }

    trait :paid do
      payment_status    { "paid" }
      amount_paid_cents { 2500 }
    end
  end
end
