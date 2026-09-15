# frozen_string_literal: true

module Storage
  # Absolute URL for an Active Storage blob, for code with **no request in
  # scope** — jobs and services.
  #
  # This exists because getting it wrong is silent and total. A controller can
  # say `url_for(blob)` and Rails takes the host from the incoming request,
  # which is the API domain, and it works. A job has no request, so it must be
  # told the host — and the obvious thing to reach for,
  # `action_mailer.default_url_options`, is deliberately set to **FRONTEND_URL**
  # (see config/environments/production.rb) because mailer links should point at
  # the frontend.
  #
  # A blob is not a mailer link. `/rails/active_storage/blobs/redirect/...` is
  # served by *Rails*, behind the ALB on the API domain. Pointed at the frontend
  # instead, every generated URL is a CloudFront path that doesn't exist, and the
  # failure only shows up when somebody clicks it: certificates and previews were
  # stored with URLs that 404ed for every participant and every organizer.
  #
  # BACKEND_URL is the same value the ABA webhook callbacks already use for
  # "where is this API reachable from outside" (PaymentsController,
  # EventPlanPaymentsController), so there is no new thing to configure —
  # infrastructure/ecs.tf sets it on both the web and worker tasks.
  module BlobUrl
    # A rails_blob_url carries the blob's signed id in its path, between the
    # redirect/proxy segment and the filename:
    #
    #   https://api.example.com/rails/active_storage/blobs/redirect/<signed_id>/name.odt
    #
    # Matches both `redirect` (the default) and `proxy`, since which one Rails
    # generates depends on configuration that could change later.
    BLOB_SIGNED_ID = %r{/blobs/(?:redirect|proxy)/([^/]+)/}

    def self.call(blob)
      Rails.application.routes.url_helpers.rails_blob_url(blob, **url_options)
    end

    # The inverse of .call: recover the blob from a URL this app generated.
    #
    # Needed because several columns store a *URL* rather than a blob id —
    # Event#certificate_template_url, Certificate#file_url,
    # CertificatePreview#file_url — a deliberate choice explained in
    # Certificates::RenderPdf's class comment. Anything that has to act on the
    # underlying blob (render it, purge it) therefore has to get back from the
    # URL to the record.
    #
    # Returns nil rather than raising for a blank, foreign, malformed or
    # already-purged URL. Every caller is doing something optional — offering a
    # preview, cleaning up a file — and none should fail loudly because one row
    # holds a URL from an older scheme.
    def self.find_by_url(url)
      signed_id = url.to_s[BLOB_SIGNED_ID, 1]
      return nil if signed_id.blank?

      ActiveStorage::Blob.find_signed(signed_id)
    rescue StandardError => e
      Rails.logger.warn("[blob url] could not resolve #{url.inspect}: #{e.class}: #{e.message}")
      nil
    end

    # Falls back to the mailer options only when BACKEND_URL is unset, which is
    # the case in development and test — where the mailer host (localhost:3000 /
    # example.com) *is* the Rails host, so it happens to be correct there. That
    # is exactly why this bug survived: the fallback is right everywhere except
    # production.
    def self.url_options
      backend = ENV["BACKEND_URL"].presence
      return mailer_url_options if backend.nil?

      uri = URI.parse(backend)
      return mailer_url_options if uri.host.blank?

      { protocol: uri.scheme, host: uri.host, port: significant_port(uri) }.compact
    rescue URI::InvalidURIError
      Rails.logger.warn("[blob url] BACKEND_URL is not a valid URI: #{backend.inspect}")
      mailer_url_options
    end

    # URI#port always answers, filling in the scheme default, so passing it
    # through unconditionally would render "https://host:443/...". Valid, but
    # it leaks into stored URLs and into anything comparing them.
    def self.significant_port(uri)
      default = uri.scheme == "https" ? 443 : 80
      uri.port unless uri.port == default
    end

    def self.mailer_url_options
      Rails.application.config.action_mailer.default_url_options || {}
    end

    private_class_method :url_options, :significant_port, :mailer_url_options
  end
end
