FactoryBot.define do
  factory :platform_payment do
    association :registration
    provider { "aba_payway" }
    sequence(:tran_id) { |n| "plftest#{n}" }
    status   { "pending" }
    currency { "usd" }

    # A $25 registration on a notional 12% commission. The split has to add up
    # or both the model validation and the CHECK constraint reject it, so
    # overriding any one of these three in a spec means overriding the others.
    gross_amount_cents { 2500 }
    platform_fee_cents { 300 }
    host_net_cents     { 2200 }

    expires_at { 15.minutes.from_now }

    trait :authorized do
      status          { "authorized" }
      authorized_at   { Time.current }
      hold_expires_at { PlatformPayment::AUTHORIZATION_WINDOW.from_now }
    end

    trait :captured do
      status          { "captured" }
      authorized_at   { 1.hour.ago }
      captured_at     { Time.current }
      hold_expires_at { PlatformPayment::AUTHORIZATION_WINDOW.from_now }
    end

    trait :qr_expired do
      expires_at { 1.minute.ago }
    end

    trait :hold_expired do
      status          { "authorized" }
      authorized_at   { (PlatformPayment::AUTHORIZATION_WINDOW + 1.day).ago }
      hold_expires_at { 1.day.ago }
    end
  end
end
