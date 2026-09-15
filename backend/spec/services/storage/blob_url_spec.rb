require "rails_helper"

RSpec.describe Storage::BlobUrl do
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("%PDF-1.4"), filename: "certificate.pdf", content_type: "application/pdf"
    )
  end

  # The regression this class exists for. BACKEND_URL is the API host; the
  # mailer host is FRONTEND_URL, which serves CloudFront and has no
  # /rails/active_storage route — so a blob URL built from it 404s for every
  # participant and organizer, and nothing notices until somebody clicks.
  it "builds the URL on the API host, not the mailer host" do
    allow(Rails.application.config.action_mailer).to receive(:default_url_options)
      .and_return({ host: "rally.example.com" })

    url = with_backend_url("https://rally-api.example.com") { described_class.call(blob) }

    expect(url).to start_with("https://rally-api.example.com/rails/active_storage/")
    expect(url).not_to include("rally.example.com/rails")
  end

  it "omits the port when it's the scheme default" do
    url = with_backend_url("https://rally-api.example.com") { described_class.call(blob) }

    expect(url).not_to include(":443")
  end

  it "keeps a non-default port, for an ALB or a local API on another port" do
    url = with_backend_url("http://alb.internal:3001") { described_class.call(blob) }

    expect(url).to include("alb.internal:3001")
  end

  # Why the bug survived: with BACKEND_URL unset the mailer host *is* the Rails
  # host, so development and test were always correct.
  it "falls back to the mailer host when BACKEND_URL is unset" do
    allow(Rails.application.config.action_mailer).to receive(:default_url_options)
      .and_return({ host: "localhost", port: 3000 })

    url = with_backend_url(nil) { described_class.call(blob) }

    expect(url).to start_with("http://localhost:3000/rails/active_storage/")
  end

  it "falls back rather than raising when BACKEND_URL is unusable" do
    allow(Rails.application.config.action_mailer).to receive(:default_url_options)
      .and_return({ host: "example.com" })

    expect {
      url = with_backend_url("not a url at all") { described_class.call(blob) }
      expect(url).to include("example.com")
    }.not_to raise_error
  end

  describe ".find_by_url" do
    # The inverse of .call, needed because several columns store a URL rather
    # than a blob id — so anything acting on the underlying blob (render it,
    # purge it) has to get back from the URL to the record.
    it "round-trips a URL this app generated back to the blob" do
      url = with_backend_url("https://rally-api.example.com") { described_class.call(blob) }

      expect(described_class.find_by_url(url)).to eq(blob)
    end

    it "round-trips regardless of which host generated it" do
      url = with_backend_url("http://alb.internal:3001") { described_class.call(blob) }

      expect(described_class.find_by_url(url)).to eq(blob)
    end

    # Every caller is doing something optional — offering a preview, cleaning
    # up a file — so one row holding a URL from an older scheme must not raise.
    it "returns nil rather than raising for anything it can't resolve" do
      [nil, "", "https://example.com/somewhere/else.pdf",
       "https://example.com/rails/active_storage/blobs/redirect/tampered/x.pdf"].each do |value|
        expect(described_class.find_by_url(value)).to be_nil
      end
    end
  end

  # Both renderers must resolve the host the same way — they had the same bug
  # because they carried the same copied fallback.
  it "is what both certificate renderers use" do
    expect(Certificates::RenderPdf.instance_method(:blob_url)).to be_present
    expect(Certificates::RenderPreview.instance_method(:blob_url)).to be_present

    expect(described_class).to receive(:call).twice.and_return("https://api.example.com/x.pdf")

    Certificates::RenderPdf.allocate.send(:blob_url, blob)
    Certificates::RenderPreview.allocate.send(:blob_url, blob)
  end

  def with_backend_url(value)
    previous = ENV["BACKEND_URL"]
    value.nil? ? ENV.delete("BACKEND_URL") : ENV["BACKEND_URL"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("BACKEND_URL") : ENV["BACKEND_URL"] = previous
  end
end
