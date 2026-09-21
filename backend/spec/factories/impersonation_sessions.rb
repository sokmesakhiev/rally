FactoryBot.define do
  factory :impersonation_session do
    association :admin, factory: :user, admin: true
    association :user
    reason { "Checking the publish error reported in ticket 412" }
    expires_at { ImpersonationSession::DURATION.from_now }

    trait :ended do
      ended_at { 1.minute.ago }
    end

    trait :revoked do
      revoked_at { 1.minute.ago }
      association :revoked_by, factory: :user, admin: true
    end

    # Deliberately written past the validation — `expires_at` is set from
    # DURATION at creation and never moved, so the only way an expired row
    # exists is time passing.
    trait :expired do
      after(:create) { |s| s.update_columns(expires_at: 1.minute.ago) }
    end
  end
end
