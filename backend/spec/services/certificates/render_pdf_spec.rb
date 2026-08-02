require "rails_helper"

# These specs mock the two real-world dependencies (downloading the
# organizer's template over HTTP, and shelling out to `soffice`) rather than
# exercising them for real — this suite has no network access to an arbitrary
# certificate_template_url, and LibreOffice isn't installed in the test
# environment. Certificates::MergeOdt itself is covered for real in
# merge_odt_spec.rb, so stubbing it out here (while still asserting on the
# arguments it was called with) keeps these specs focused on RenderPdf's own
# orchestration logic.
RSpec.describe Certificates::RenderPdf do
  let(:organizer)   { create(:user) }
  let(:participant) { create(:user) }
  let(:event) do
    create(:event, :past, creator: organizer, title: "Rally 10K", location: "Phnom Penh",
                           certificate_template_url: "https://example.com/template.odt")
  end
  let(:registration) { create(:registration, event: event, user: participant) }

  # User#after_create already builds a Profile for every user (see
  # User#create_profile!) — create(:profile, user: participant) would hit
  # Profile's `validates :user_id, uniqueness: true` against that
  # auto-created row, so update the existing one instead.
  before { participant.profile.update!(display_name: "Jane Doe") }

  def stub_template_download(bytes: "fake odt bytes")
    fake_uri = double("uri")
    allow(fake_uri).to receive(:open).and_yield(StringIO.new(bytes))
    # URI.parse is a class method on a stdlib class other code (DatabaseCleaner,
    # the PG adapter reconnecting, etc.) also calls with completely unrelated
    # arguments (e.g. the database URL) during the same example — stubbing
    # `.with(...)` alone turns those other calls into "unexpected arguments"
    # errors. `and_call_original` as a catch-all, defined *before* the
    # specific `.with` stub, keeps every other call real while only faking
    # the one we care about.
    allow(URI).to receive(:parse).and_call_original
    allow(URI).to receive(:parse).with(event.certificate_template_url).and_return(fake_uri)
    fake_uri
  end

  def stub_capture3_success
    allow(Open3).to receive(:capture3) do |*args|
      pdf_path = args.last.to_s.sub(/\.odt\z/, ".pdf")
      File.write(pdf_path, "%PDF-1.4 fake")
      [ "", "", instance_double(Process::Status, success?: true) ]
    end
  end

  describe ".call" do
    it "returns nil without attempting a download when the event has no template" do
      no_template_event = create(:event, :past, creator: organizer, certificate_template_url: nil)
      reg = create(:registration, event: no_template_event, user: participant)

      # Asserting "URI.parse was never called at all" is too broad — other
      # code (DatabaseCleaner, the PG adapter reconnecting, etc.) also calls
      # URI.parse with unrelated arguments during an example's lifecycle.
      # What actually matters here is that we returned early rather than
      # getting as far as merging a template.
      expect(Certificates::MergeOdt).not_to receive(:call)
      expect(described_class.call(reg)).to be_nil
    end

    it "downloads the template, merges the right placeholders, converts to PDF, and attaches it" do
      stub_template_download
      stub_capture3_success

      captured_replacements = nil
      allow(Certificates::MergeOdt).to receive(:call) do |destination_path:, replacements:, **|
        captured_replacements = replacements
        File.write(destination_path, "merged odt bytes")
        destination_path
      end

      certificate = described_class.call(registration)

      expect(captured_replacements).to eq(
        "participant_name" => "Jane Doe",
        "event_title"      => "Rally 10K",
        "event_date"       => event.start_at.strftime("%B %-d, %Y"),
        "event_location"   => "Phnom Penh"
      )

      expect(certificate).to be_a(Certificate)
      expect(certificate.registration).to eq(registration)
      expect(certificate.file_present?).to be(true)
      expect(certificate.file_url).to be_present
      expect(certificate.file_url).to include("certificate-#{registration.id}")

      # Persisted, not just an in-memory staging — a fresh query (like the
      # one RegistrationsController makes) has to see it too.
      expect(Certificate.find(certificate.id).file_url).to eq(certificate.file_url)
    end

    it "falls back to the user's email when they have no profile display name" do
      no_profile_user = create(:user)
      reg = create(:registration, event: event, user: no_profile_user)
      stub_template_download
      stub_capture3_success

      captured_replacements = nil
      allow(Certificates::MergeOdt).to receive(:call) do |destination_path:, replacements:, **|
        captured_replacements = replacements
        File.write(destination_path, "merged")
        destination_path
      end

      described_class.call(reg)

      expect(captured_replacements["participant_name"]).to eq(no_profile_user.email)
    end

    it "re-runs cleanly for an already-certified registration (updates, doesn't duplicate)" do
      stub_template_download
      stub_capture3_success
      allow(Certificates::MergeOdt).to receive(:call) do |destination_path:, **|
        File.write(destination_path, "merged")
        destination_path
      end

      expect {
        described_class.call(registration)
        described_class.call(registration)
      }.to change(Certificate, :count).by(1)
    end

    it "raises ConversionError when the template download fails" do
      fake_uri = double("uri")
      allow(fake_uri).to receive(:open).and_raise(SocketError, "no route to host")
      allow(URI).to receive(:parse).and_call_original
      allow(URI).to receive(:parse).with(event.certificate_template_url).and_return(fake_uri)

      expect { described_class.call(registration) }
        .to raise_error(Certificates::RenderPdf::ConversionError, /could not download/)
    end

    it "raises ConversionError when soffice exits unsuccessfully" do
      stub_template_download
      allow(Certificates::MergeOdt).to receive(:call) do |destination_path:, **|
        File.write(destination_path, "merged")
        destination_path
      end
      allow(Open3).to receive(:capture3).and_return(
        [ "", "boom", instance_double(Process::Status, success?: false) ]
      )

      expect { described_class.call(registration) }
        .to raise_error(Certificates::RenderPdf::ConversionError, /soffice conversion failed/)
    end

    it "raises ConversionError when soffice reports success but produces no file" do
      stub_template_download
      allow(Certificates::MergeOdt).to receive(:call) do |destination_path:, **|
        File.write(destination_path, "merged")
        destination_path
      end
      allow(Open3).to receive(:capture3).and_return(
        [ "", "", instance_double(Process::Status, success?: true) ]
      )

      expect { described_class.call(registration) }
        .to raise_error(Certificates::RenderPdf::ConversionError, /produced no PDF/)
    end
  end
end
