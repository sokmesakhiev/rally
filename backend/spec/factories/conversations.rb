FactoryBot.define do
  factory :conversation do
    association :user
    status  { Conversation::OPEN }
    subject { "Help with my registration" }

    trait :pending do
      status { Conversation::PENDING }
    end

    # Frees the participant's one live slot — see the partial unique index.
    trait :resolved do
      status { Conversation::RESOLVED }
    end

    trait :assigned do
      assigned_admin { create(:user, admin: true) }
    end

    # A thread with one message from each side, staff replying last.
    trait :with_exchange do
      after(:create) do |conversation|
        create(:message, conversation: conversation, sender: conversation.user,
                         body: "Where do I find my ticket?", created_at: 2.hours.ago)
        create(:message, :from_staff, conversation: conversation,
                         body: "It's on your dashboard.", created_at: 1.hour.ago)
      end
    end
  end
end
