FactoryBot.define do
  factory :event do
    association :creator, factory: :user
    title       { Faker::Lorem.sentence(word_count: 3).chomp(".") }
    description { Faker::Lorem.paragraph }
    category    { Event::CATEGORIES.sample }
    location    { Faker::Address.city }
    start_at    { 1.week.from_now }
    end_at      { 2.weeks.from_now }
    price_cents { 0 }
    currency    { "usd" }
    is_published { true }
    brand_color { "#6366f1" }

    trait :draft do
      is_published { false }
    end

    trait :paid do
      price_cents { 2500 }
    end

    trait :full do
      capacity { 1 }
      after(:create) do |event|
        other = create(:user)
        create(:registration, event: event, user: other)
      end
    end

    trait :past do
      start_at { 2.weeks.ago }
      end_at   { 1.week.ago }
    end
  end
end
