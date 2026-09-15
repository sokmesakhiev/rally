# frozen_string_literal: true

require "open3"

module Certificates
  # Shells out to LibreOffice headless to render an .odt to PDF.
  #
  # Extracted from Certificates::RenderPdf when certificate *previews* were
  # added: both paths merge an organizer's template and convert it, and they
  # differ only in where the template comes from and what happens to the
  # result. Duplicating the soffice invocation would have meant two places to
  # get the profile-isolation flag wrong, and a preview that renders
  # differently from the certificate it is supposed to be previewing is worse
  # than no preview at all.
  #
  # There is no pure-Ruby way to get faithful ODT->PDF rendering (page layout,
  # fonts, embedded images), so `soffice` is a genuine runtime dependency —
  # see backend/Dockerfile, which also installs fonts-dejavu-core. A template
  # naming a font that isn't in that image renders here with a substitute,
  # silently moving every line.
  class OdtToPdf
    class ConversionError < StandardError; end

    # Conversion is CPU- and memory-heavy: measured at roughly 0.25-1.2s and
    # ~180 MB peak RSS for a simple one-page certificate. On a 0.5 vCPU /
    # 1 GB task that is not something to run inside a request — both callers
    # are background jobs, deliberately.
    def self.call(odt_path:, workdir:)
      new(odt_path, workdir).call
    end

    def initialize(odt_path, workdir)
      @odt_path = odt_path
      @workdir = workdir
    end

    # `-env:UserInstallation=` gives this one conversion its own LibreOffice
    # profile directory. Without it, two `soffice` invocations running at
    # the same time (e.g. two certificates rendering back to back) share the
    # default profile and can lock each other out — a well-known LibreOffice
    # headless gotcha, not a hypothetical one. It matters more now that
    # previews are organizer-triggered and so can genuinely coincide with the
    # end-of-event certificate sweep.
    #
    # Brakeman flags the Open3.capture3 call below as "possible command
    # injection" because one argument is built via string interpolation —
    # that check is a blunt heuristic and doesn't distinguish this from a
    # real risk here. Two independent reasons it isn't:
    #   1. Open3.capture3(*array) execs the array directly (execve), never
    #      through /bin/sh — there's no shell to interpret ";", "|", "$()",
    #      backticks, etc. even if a segment contained them.
    #   2. Every interpolated segment (workdir, profile_dir, odt_path) is
    #      built purely from Dir.mktmpdir/File.join by the caller — none of
    #      it is organizer- or participant-controlled input (that data only
    #      ever reaches Certificates::MergeOdt's XML-escaped substitution,
    #      never this command).
    def call
      profile_dir = File.join(@workdir, "lo_profile")
      command = [
        "soffice", "--headless", "--norestore",
        "--convert-to", "pdf",
        "--outdir", @workdir,
        "-env:UserInstallation=file://#{profile_dir}",
        @odt_path
      ]

      stdout, stderr, status = Open3.capture3(*command)
      raise ConversionError, "soffice conversion failed: #{stderr.presence || stdout}" unless status.success?

      pdf_path = @odt_path.sub(/\.odt\z/, ".pdf")
      raise ConversionError, "soffice reported success but produced no PDF" unless File.exist?(pdf_path)

      pdf_path
    end
  end
end
