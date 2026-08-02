FactoryBot.define do
  factory :certificate do
    association :registration

    # Plain `create(:certificate)` deliberately leaves file_url blank —
    # most specs only care about the row/uniqueness-validation existing,
    # not a real PDF. Use `:with_file` when a spec needs
    # `certificate.file_url` to actually be present (e.g. asserting
    # `certificate_url` is exposed by the API).
    trait :with_file do
      file_url { "https://example-bucket.s3.amazonaws.com/certificates/fake.pdf" }
    end
  end
end
