FactoryBot.define do
  factory :push_subscription do
    association :user
    # Shaped like a real FCM endpoint — the schema insists on https, and a
    # bare "endpoint-1" would pass the model but not the request schema.
    sequence(:endpoint) { |n| "https://fcm.googleapis.com/fcm/send/test-endpoint-#{n}" }
    p256dh_key { "BOrLl6ZoPGpzZ1oXQ6t7bDkTestPublicKeyValueForSpecs00000000000000000000000000000" }
    auth_key   { "c2VjcmV0LWF1dGgta2V5" }
    user_agent { "Mozilla/5.0 (Macintosh) Chrome/140.0" }

    trait :expired do
      expired_at { 1.day.ago }
    end
  end
end
