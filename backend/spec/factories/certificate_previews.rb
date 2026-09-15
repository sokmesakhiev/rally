FactoryBot.define do
  factory :certificate_preview do
    association :user
    association :event
    status { "pending" }
    # A plain id rather than a real blob: most examples never open it, and the
    # ones that do stub the blob lookup. See the migration for why this column
    # isn't a foreign key.
    template_blob_id { 1 }

    trait :ready do
      status { "ready" }
      file_url { "https://example.com/rails/active_storage/blobs/redirect/abc123/preview.pdf" }
    end

    trait :failed do
      status { "failed" }
      error_code { "conversion_failed" }
    end

    trait :stale do
      updated_at { CertificatePreview::RETENTION.ago - 1.hour }
    end
  end
end
