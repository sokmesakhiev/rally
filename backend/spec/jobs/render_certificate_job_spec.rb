require "rails_helper"

RSpec.describe RenderCertificateJob, type: :job do
  let(:organizer)     { create(:user) }
  let(:participant)   { create(:user) }
  let(:event)         { create(:event, :past, creator: organizer, certificate_template_url: "https://example.com/t.odt") }
  let(:registration)  { create(:registration, event: event, user: participant) }

  it "delegates to Certificates::RenderPdf for the given registration" do
    expect(Certificates::RenderPdf).to receive(:call).with(registration)

    described_class.perform_now(registration.id)
  end

  it "does nothing when the registration no longer exists" do
    expect(Certificates::RenderPdf).not_to receive(:call)

    expect { described_class.perform_now("00000000-0000-0000-0000-000000000000") }.not_to raise_error
  end

  it "logs and swallows a ConversionError instead of re-raising" do
    allow(Certificates::RenderPdf).to receive(:call)
      .and_raise(Certificates::RenderPdf::ConversionError, "soffice conversion failed: boom")

    expect(Rails.logger).to receive(:error).with(/failed to render for registration=#{registration.id}/)

    expect { described_class.perform_now(registration.id) }.not_to raise_error
  end
end
