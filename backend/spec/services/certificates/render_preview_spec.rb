require "rails_helper"

RSpec.describe Certificates::RenderPreview do
  let(:organizer) { create(:user) }
  let(:event) do
    create(:event, creator: organizer, title: "Angkor Wat Half Marathon",
                   start_at: Time.utc(2026, 9, 14, 6, 0), location: "Siem Reap")
  end
  let(:preview) { create(:certificate_preview, user: organizer, event: event) }

  # The preview must show what the certificate will show. If these two ever
  # format differently, the preview is lying about the one thing it exists for.
  describe "sample values" do
    it "uses the same keys and the same date format as RenderPdf" do
      participant = create(:user)
      registration = create(:registration, event: event, user: participant)

      preview_values = described_class.new(preview).send(:placeholder_values)
      real_values = Certificates::RenderPdf.new(registration).send(:placeholder_values)

      expect(preview_values.keys).to match_array(real_values.keys)
      expect(preview_values["event_title"]).to eq(real_values["event_title"])
      expect(preview_values["event_date"]).to eq(real_values["event_date"])
      expect(preview_values["event_location"]).to eq(real_values["event_location"])
    end

    it "uses the organizer's display name as the sample participant" do
      # Update, don't create: User#after_create already calls create_profile!,
      # so building another hits Profile's `validates :user_id, uniqueness`.
      # Same trap render_pdf_spec.rb flags two files over.
      organizer.profile.update!(display_name: "Sokmesa Khiev")

      values = described_class.new(preview).send(:placeholder_values)

      expect(values["participant_name"]).to eq("Sokmesa Khiev")
    end

    # Same fallback RenderPdf uses for a real participant — and the case that
    # produces the longest, most layout-breaking value, so it is worth being
    # able to see it in a preview.
    it "falls back to the organizer's email when they have no display name" do
      values = described_class.new(preview).send(:placeholder_values)

      expect(values["participant_name"]).to eq(organizer.email)
    end

    it "renders a blank location rather than nil when the event has none" do
      event.update!(location: nil)

      expect(described_class.new(preview).send(:placeholder_values)["event_location"]).to eq("")
    end
  end

  describe "failure handling" do
    it "marks the preview failed when the template blob has been purged" do
      allow(preview).to receive(:template_blob).and_return(nil)

      described_class.call(preview)

      expect(preview.reload).to be_failed
      expect(preview.error_code).to eq("template_missing")
    end

    # Every expected failure becomes a `failed` row rather than an exception,
    # because a preview that silently never arrives is worse for the organizer
    # than one that says why.
    it "marks the preview failed, not raised, when soffice cannot convert" do
      stub_template_blob
      allow(Certificates::OdtToPdf).to receive(:call)
        .and_raise(Certificates::OdtToPdf::ConversionError, "soffice conversion failed: boom")

      expect { described_class.call(preview) }.not_to raise_error

      expect(preview.reload).to be_failed
      expect(preview.error_code).to eq("conversion_failed")
    end

    it "clears a previously rendered file when a re-render fails" do
      preview.update!(status: "ready", file_url: "https://example.com/old.pdf")
      allow(preview).to receive(:template_blob).and_return(nil)

      described_class.call(preview)

      expect(preview.reload.file_url).to be_nil
    end
  end

  describe "success" do
    it "stores the pdf and marks the preview ready" do
      stub_template_blob
      allow(Certificates::OdtToPdf).to receive(:call) do |odt_path:, workdir:|
        pdf = File.join(workdir, "preview.pdf")
        File.binwrite(pdf, "%PDF-1.4 fake")
        pdf
      end

      described_class.call(preview)

      expect(preview.reload).to be_ready
      expect(preview.file_url).to be_present
      expect(preview.error_code).to be_nil
    end
  end

  # A minimal but real .odt, so MergeOdt runs for real rather than being stubbed
  # — the substitution is the part most likely to break.
  def stub_template_blob
    odt = Tempfile.new([ "template", ".odt" ])
    Zip::OutputStream.open(odt.path) do |out|
      out.put_next_entry("content.xml")
      out.write("<text:p>{{participant_name}} — {{event_title}}</text:p>")
      out.put_next_entry("styles.xml")
      out.write("<styles>{{event_date}} {{event_location}}</styles>")
    end

    blob = double("blob")
    allow(blob).to receive(:open).and_yield(odt)
    allow(preview).to receive(:template_blob).and_return(blob)
  end
end
