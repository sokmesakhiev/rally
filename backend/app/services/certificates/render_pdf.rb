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
    class ConversionError < StandardError; end

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

    # `-env:UserInstallation=` gives this one conversion its own LibreOffice
    # profile directory. Without it, two `soffice` invocations running at
    # the same time (e.g. two certificates rendering back to back) share the
    # default profile and can lock each other out — a well-known LibreOffice
    # headless gotcha, not a hypothetical one.
    #
    # Brakeman flags the Open3.capture3 call below as "possible command
    # injection" because one argument is built via string interpolation —
    # that check is a blunt heuristic and doesn't distinguish this from a
    # real risk here. Two independent reasons it isn't:
    #   1. Open3.capture3(*array) execs the array directly (execve), never
    #      through /bin/sh — there's no shell to interpret ";", "|", "$()",
    #      backticks, etc. even if a segment contained them.
    #   2. Every interpolated segment (workdir, profile_dir, odt_path) is
    #      built purely from Dir.mktmpdir/File.join inside this service —
    #      none of it is organizer- or participant-controlled input (that
    #      data only ever reaches Certificates::MergeOdt's XML-escaped
    #      substitution, never this command).
    def convert_to_pdf(odt_path, workdir)
      profile_dir = File.join(workdir, "lo_profile")
      command = [
        "soffice", "--headless", "--norestore",
        "--convert-to", "pdf",
        "--outdir", workdir,
        "-env:UserInstallation=file://#{profile_dir}",
        odt_path
      ]

      stdout, stderr, status = Open3.capture3(*command)
      raise ConversionError, "soffice conversion failed: #{stderr.presence || stdout}" unless status.success?

      pdf_path = odt_path.sub(/\.odt\z/, ".pdf")
      raise ConversionError, "soffice reported success but produced no PDF" unless File.exist?(pdf_path)

      pdf_path
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

    # Mirrors UploadsController's `url_for(blob)`, but this is a plain
    # service class (job-invoked, no request in scope) rather than a
    # controller, so there's no request to infer a host from — reuse the
    # host/port already configured for ActionMailer per environment (see
    # config/environments/*.rb) instead of requiring a separate setting.
    def blob_url(blob)
      options = Rails.application.config.action_mailer.default_url_options || {}
      Rails.application.routes.url_helpers.rails_blob_url(blob, **options)
    end
  end
end
