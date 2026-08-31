FactoryBot.define do
  factory :event do
    creator { association :user }
    # Owned by the event's own creator, so `create(:event, creator: someone)`
    # keeps meaning "someone runs this event" — both via creator_id and via
    # the organization. Pass `organization:` explicitly to model the case
    # this doesn't cover: an event created by a colleague under a club's
    # organization (see trait :for_organization below).
    #
    # Verification is inherited from the creator, mirroring what #338's
    # backfill did in production: a verified organizer's organizations came
    # out verified, so `create(:user, :verified)` still means "can run paid
    # events" now that the gate reads the organization rather than the user.
    organization { association :organization, owner: creator, verified_at: creator.verified_at }
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

    # An event whose presenting organization is NOT owned by its creator —
    # the club case. Use when a spec needs creator and organization to come
    # apart, e.g. proving an org admin can manage a colleague's event.
    trait :for_organization do
      transient do
        presented_by { nil }
      end

      organization { presented_by || association(:organization) }
    end
  end
end
