FactoryBot.define do
  factory :refund do
    association :payment, :approved
    association :initiated_by, factory: :user
    amount_cents { 2500 }
    refund_method { "gateway" }
    status { "succeeded" }
    refunded_at { Time.current }

    trait :manual do
      refund_method { "manual" }
      reason { "Refunded via bank transfer outside PayWay" }
    end

    trait :failed do
      status { "failed" }
      refunded_at { nil }
    end
  end
end
