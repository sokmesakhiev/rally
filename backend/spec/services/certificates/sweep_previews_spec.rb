require "rails_helper"

RSpec.describe Certificates::SweepPreviews do
  it "removes previews past the retention window" do
    stale = create(:certificate_preview, :ready, :stale)
    fresh = create(:certificate_preview, :ready)

    expect(described_class.call).to eq(1)

    expect(CertificatePreview.exists?(stale.id)).to be false
    expect(CertificatePreview.exists?(fresh.id)).to be true
  end

  it "does nothing and reports zero when everything is fresh" do
    create(:certificate_preview, :ready)

    expect(described_class.call).to eq(0)
    expect(CertificatePreview.count).to eq(1)
  end

  # The whole reason this sweep exists: the row only ever holds the newest
  # URL, so every re-render orphans the previous PDF in storage.
  it "purges the rendered pdf, not just the row" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("%PDF-1.4"), filename: "preview.pdf", content_type: "application/pdf"
    )
    url = Rails.application.routes.url_helpers.rails_blob_url(blob, host: "example.com")
    create(:certificate_preview, :stale, status: "ready", file_url: url)

    expect { described_class.call }.to have_enqueued_job(ActiveStorage::PurgeJob)
  end

  # One unparseable URL must not strand every row behind it — the worst case
  # is a single orphaned object, not a sweep that stops half way.
  it "keeps sweeping when one preview's file url can't be resolved" do
    create(:certificate_preview, :stale, status: "ready", file_url: "https://example.com/nonsense")
    other = create(:certificate_preview, :stale, :ready)

    expect { described_class.call }.not_to raise_error
    expect(CertificatePreview.exists?(other.id)).to be false
  end

  it "sweeps failed and pending previews too, not just finished ones" do
    create(:certificate_preview, :stale, status: "failed", error_code: "conversion_failed")
    create(:certificate_preview, :stale, status: "pending")

    expect(described_class.call).to eq(2)
    expect(CertificatePreview.count).to eq(0)
  end
end
