# frozen_string_literal: true

require "open-uri"
require "open3"
require "tmpdir"

module Certificates
  # Turns one registration into a downloadable PDF certificate of
  # participation: downloads the event's organizer-uploaded .odt template,
  # merges in participant/event data (Certificates::MergeOdt), then shells
  # out to LibreOffice headless to render the merged .odt to PDF — there's no
  # pure-Ruby way to get faithful ODT→PDF rendering (page layout, fonts,
  # embedded images), so this is a genuine runtime dependency on `soffice`
  # being installed (see the Dockerfile).
  #
  # Called per-registration by GenerateCertificatesJob. Deliberately does
  # nothing (returns nil) rather than raising when the event has no template
  # — that's a normal, common state (certificates are opt-in), not an error.
  #
  # Stores the finished PDF as a plain Certificate#file_url string (via
  # ActiveStorage::Blob.create_and_upload!), the same way Event's
  # banner_url/logo_url/certificate_template_url work — deliberately NOT
  # has_one_attached. has_one_attached's ActiveStorage::Attachment join row
  # turned out not to be reliably visible to a *separate* query (e.g. the
  # request spec hitting RegistrationsController right after a factory
  # created one) within a test running under DatabaseCleaner's
  # `:transaction` strategy, even after an explicit save — a standalone
  # blob is the only file-storage path this codebase actually has proven
  # to work end-to-end in tests.
  class RenderPdf
    # Deliberately the *same* class as OdtToPdf's, not a sibling of it.
    # RenderCertificateJob rescues Certificates::RenderPdf::ConversionError to
    # log-and-swallow a bad template, and three specs assert on it; once the
    # soffice call moved into OdtToPdf, a separate class here would have
    # quietly stopped that rescue from catching conversion failures, turning a
    # logged warning into a crashed job. An alias keeps both the raise sites
    # (download failure below, conversion failure in OdtToPdf) under one name.
    ConversionError = Certificates::OdtToPdf::ConversionError

    def self.call(registration)
      new(registration).call
    end

    def initialize(registration)
      @registration = registration
      @event = registration.event
    end

    def call
      return nil unless @event.certificate_template?

      Dir.mktmpdir("certificate-") do |dir|
        template_path = File.join(dir, "template.odt")
        merged_path   = File.join(dir, "merged.odt")

        download_template(template_path)
        Certificates::MergeOdt.call(
          source_path: template_path,
          destination_path: merged_path,
          replacements: placeholder_values
        )

        pdf_path = convert_to_pdf(merged_path, dir)
        attach!(pdf_path)
      end
    end

    private

    def download_template(destination)
      URI.parse(@event.certificate_template_url).open("rb") do |remote|
        File.binwrite(destination, remote.read)
      end
    rescue OpenURI::HTTPError, SocketError, Timeout::Error, Errno::ECONNREFUSED => e
      raise ConversionError, "could not download certificate template: #{e.message}"
    end

    def placeholder_values
      {
        "participant_name" => participant_name,
        "event_title"      => @event.title,
        "event_date"       => @event.start_at.strftime("%B %-d, %Y"),
        "event_location"   => @event.location.presence || ""
      }
    end

    def participant_name
      @registration.user.profile&.display_name.presence || @registration.user.email
    end

    # Moved to Certificates::OdtToPdf when previews were added, so a preview
    # and the certificate it previews go through byte-for-byte the same
    # conversion. See that class for the soffice profile-isolation flag and
    # the Brakeman note.
    def convert_to_pdf(odt_path, workdir)
      Certificates::OdtToPdf.call(odt_path: odt_path, workdir: workdir)
    end

    def attach!(pdf_path)
      certificate = Certificate.find_or_initialize_by(registration: @registration)

      blob = File.open(pdf_path, "rb") do |f|
        ActiveStorage::Blob.create_and_upload!(
          io: f,
          filename: "certificate-#{@registration.id}.pdf",
          content_type: "application/pdf"
        )
      end

      certificate.file_url = blob_url(blob)
      certificate.save!
      certificate
    end

    # This used to build the URL from `action_mailer.default_url_options`,
    # reasoning that a job has no request to infer a host from. The host it
    # picked up was FRONTEND_URL — correct for a mailer link, wrong for a blob,
    # which Rails serves on the API domain. Every certificate rendered in
    # production was therefore stored with a CloudFront URL that 404s.
    # See Storage::BlobUrl. **Rows written before that fix still hold the bad
    # host and need rewriting.**
    def blob_url(blob)
      Storage::BlobUrl.call(blob)
    end
  end
end
