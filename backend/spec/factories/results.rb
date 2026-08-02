FactoryBot.define do
  factory :result do
    association :registration
    finish_time_seconds { 5025 } # 1:23:45
  end
end
