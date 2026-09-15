# frozen_string_literal: true

module Certificates
  # Deletes certificate previews that have gone stale, and the PDFs they
  # produced.
  #
  # The one-row-per-organizer-per-event index already bounds the *table* — a
  # re-preview overwrites rather than appends. What it does not bound is
  # storage: each render creates a new Active Storage blob, and the row only
  # keeps a URL to the newest one, so every overwrite orphans the previous
  # PDF. Without this sweep those accumulate in S3 forever, unreferenced and
  # invisible, which is the quiet kind of cost nobody notices until the bill.
  #
  # Rows are removed rather than just blanked. A preview is scratch by
  # definition (CertificatePreview::RETENTION), and an organizer returning a
  # week later wants a render of whatever their template is *now*, not a
  # week-old picture of what it used to be.
  class SweepPreviews
    def self.call(now: Time.current)
      new(now).call
    end

    def initialize(now)
      @now = now
    end

    def call
      previews = CertificatePreview.stale(@now)
      count = previews.count
      return 0 if count.zero?

      previews.find_each do |preview|
        purge_pdf(preview)
        preview.destroy
      end

      Rails.logger.info("[certificate previews] swept #{count} stale preview(s)")
      count
    end

    private

    # The row stores a URL, not a blob id (same plain-URL pattern as
    # Certificate#file_url), so the blob has to be recovered from it —
    # Storage::BlobUrl.find_by_url, which already returns nil rather than
    # raising for an unparseable or purged URL. That matters here: one bad row
    # must not stop the sweep from clearing the rest, and the worst case is a
    # single orphaned object instead of every row after it surviving.
    def purge_pdf(preview)
      Storage::BlobUrl.find_by_url(preview.file_url)&.purge_later
    end
  end
end
