FactoryBot.define do
  factory :staff_approval do
    association :requester, factory: :user, staff_role: "admin"
    association :target, factory: :event
    action { "delete_event" }
    payload { {} }
    reason { "Duplicate listing, organizer asked us to remove it" }
    status { "pending" }
    expires_at { StaffApproval::LIFETIME.from_now }

    # The digest is derived, never passed in — a factory that let a caller set
    # it independently of the payload would happily build the exact mismatch
    # the pinning exists to catch.
    after(:build) do |approval|
      approval.payload_digest = StaffApproval.digest_for(
        action: approval.action,
        target_type: approval.target_type,
        target_id: approval.target_id,
        payload: approval.payload
      )
    end

    trait :approved do
      status { "approved" }
      approved_at { Time.current }
      association :approver, factory: :user, staff_role: "admin"
    end

    trait :expired do
      expires_at { 1.minute.ago }
    end

    trait :consumed do
      status { "consumed" }
      consumed_at { Time.current }
    end
  end
end
