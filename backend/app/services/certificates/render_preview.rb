# frozen_string_literal: true

require "tmpdir"

module Certificates
  # Renders an organizer's sample certificate from a CertificatePreview row.
  #
  # The participant-facing sibling is Certificates::RenderPdf. The two differ
  # in three ways that are each deliberate:
  #
  #   - **Source.** RenderPdf downloads event.certificate_template_url over
  #     HTTP, because by then the template is saved on the event. A preview
  #     runs on a template that has been *uploaded but not saved* — that is
  #     the entire point, since an organizer wants to look before committing —
  #     so it reads the Active Storage blob directly. Reading the blob also
  #     means no outbound HTTP at all, which is what keeps the preview
  #     endpoint from being an SSRF hole.
  #   - **Sample values.** Real event details, with the organizer's own name
  #     standing in for the participant. Dummy data ("Jane Doe", "Sample
  #     Event") would hide the failure this is most useful for: a real event
  #     title that wraps to two lines and pushes the layout off the page.
  #   - **Outcome.** Writes file_url/status back onto the preview row instead
  #     of creating a Certificate. Nothing here is participant-visible.
  #
  # Merging and conversion themselves are shared (MergeOdt, OdtToPdf), so a
  # preview cannot render differently from the certificate it previews.
  class RenderPreview
    def self.call(preview)
      new(preview).call
    end

    def initialize(preview)
      @preview = preview
      @event = preview.event
    end

    def call
      blob = @preview.template_blob
      return fail!("template_missing") if blob.nil?

      Dir.mktmpdir("certificate-preview-") do |dir|
        template_path = File.join(dir, "template.odt")
        merged_path   = File.join(dir, "preview.odt")

        blob.open(tmpdir: dir) { |f| FileUtils.cp(f.path, template_path) }

        Certificates::MergeOdt.call(
          source_path: template_path,
          destination_path: merged_path,
          replacements: placeholder_values
        )

        pdf_path = Certificates::OdtToPdf.call(odt_path: merged_path, workdir: dir)
        @preview.update!(status: "ready", file_url: store(pdf_path), error_code: nil)
      end

      @preview
    rescue Certificates::OdtToPdf::ConversionError => e
      # Almost always a template LibreOffice can't open. The organizer gets a
      # translated "we couldn't render this", never the soffice stderr, which
      # is full of container paths and means nothing to them.
      Rails.logger.warn("[certificate preview #{@preview.id}] conversion failed: #{e.message}")
      fail!("conversion_failed")
    rescue Zip::Error => e
      # MergeOdt reopens the archive; a file that passed InspectTemplate at
      # upload can still be malformed in a part we didn't inspect.
      Rails.logger.warn("[certificate preview #{@preview.id}] bad archive: #{e.message}")
      fail!("not_an_odt")
    end

    private

    # Mirrors Certificates::RenderPdf#placeholder_values exactly — same keys,
    # same date format. A spec pins the two together: if a preview formatted
    # the date differently from the real certificate, the preview would be
    # lying about the thing it exists to show.
    def placeholder_values
      {
        "participant_name" => sample_participant_name,
        "event_title"      => @event.title,
        "event_date"       => @event.start_at.strftime("%B %-d, %Y"),
        "event_location"   => @event.location.presence || ""
      }
    end

    # The organizer previewing it, exactly as RenderPdf would resolve a real
    # participant: display name, falling back to the account email. Using the
    # same resolution means the preview also demonstrates the email fallback
    # for an organizer whose own profile has no display name — which is
    # precisely the case that produces the longest, most layout-breaking value.
    def sample_participant_name
      @preview.user.profile&.display_name.presence || @preview.user.email
    end

    def store(pdf_path)
      blob = File.open(pdf_path, "rb") do |f|
        ActiveStorage::Blob.create_and_upload!(
          io: f,
          filename: "certificate-preview-#{@preview.id}.pdf",
          content_type: "application/pdf"
        )
      end

      blob_url(blob)
    end

    # Same host resolution as Certificates::RenderPdf#blob_url — a job has no
    # request in scope, so the ActionMailer default_url_options are reused
    # rather than introducing a second setting that could drift from it.
    def blob_url(blob)
      options = Rails.application.config.action_mailer.default_url_options || {}
      Rails.application.routes.url_helpers.rails_blob_url(blob, **options)
    end

    def fail!(code)
      @preview.update!(status: "failed", error_code: code, file_url: nil)
      @preview
    end
  end
end
