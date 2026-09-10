FactoryBot.define do
  factory :message do
    association :conversation
    body { "Is there parking at the venue?" }

    # sender defaults to the conversation's own participant, so the model's
    # before_validation lands on "participant" without the factory hardcoding
    # a role — the derivation is what most specs actually want to exercise.
    sender { conversation.user }

    trait :from_staff do
      sender { create(:user, admin: true) }
    end

    trait :from_system do
      sender { nil }
      sender_role { Message::SYSTEM }
      body { "This conversation was resolved." }
    end
  end
end
