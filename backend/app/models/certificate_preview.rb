# frozen_string_literal: true

# One organizer's rendered sample of one event's certificate template.
#
# Distinct from Certificate, which is a participant-facing artefact with a
# permanent one-per-registration identity. A preview is scratch: it is
# overwritten on every re-render, swept after a day, and nobody outside the
# organizer ever sees it. Sharing a table would have meant a "is this real?"
# flag on a record that participants can download, which is exactly the kind
# of conditional that eventually leaks the wrong file to the wrong person.
class CertificatePreview < ApplicationRecord
  STATUSES = %w[pending ready failed].freeze

  # How long a finished preview stays useful. Also what the hourly sweep
  # (Certificates::SweepPreviews, config/recurring.yml) prunes against. A day
  # is generous for "I uploaded a template and want to look at it", and short
  # enough that abandoned renders don't sit in S3 indefinitely.
  RETENTION = 24.hours

  belongs_to :user
  belongs_to :event

  validates :status, inclusion: { in: STATUSES }
  # Matches the partial-free unique index in the migration. Stated here too
  # because a model that permits what the database rejects turns a clear
  # validation error into a RecordNotUnique surfacing as a 500 — the same
  # pairing as Registration's kept-index and Conversation's one-live-thread.
  validates :user_id, uniqueness: { scope: :event_id }

  scope :stale, ->(now = Time.current) { where(updated_at: ...(now - RETENTION)) }

  def ready?   = status == "ready"
  def failed?  = status == "failed"
  def pending? = status == "pending"

  # The blob this preview was rendered from, or nil if it has since been
  # purged. Callers must handle nil — see the migration's note on why this
  # is a plain id rather than a foreign key.
  def template_blob
    ActiveStorage::Blob.find_by(id: template_blob_id)
  end
end
