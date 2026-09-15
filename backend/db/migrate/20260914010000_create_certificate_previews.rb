class CreateCertificatePreviews < ActiveRecord::Migration[8.1]
  # A rendered sample of an organizer's certificate template, so they can see
  # what participants will actually receive before an event ends and real
  # certificates go out. Rendering shells out to LibreOffice (~1-4s, ~180 MB
  # resident), which is far too heavy for a request thread on a 0.5 vCPU /
  # 1 GB task — so the render is a job and this row is how the browser follows
  # it.
  #
  # **One row per organizer per event**, enforced by the unique index below.
  # That is the whole storage-growth story: previews are throwaway, and
  # without this constraint every click of a Preview button would leave
  # another row and another orphaned PDF in S3 forever. Re-previewing
  # overwrites in place instead, so the table is bounded by
  # (organizers x events) rather than by clicks, and the hourly sweep
  # (config/recurring.yml) only has to handle genuinely stale rows.
  #
  # Deliberately NOT a status column on events: the preview belongs to the
  # person looking at it, not to the event. Two people managing the same
  # event can each have their own in flight, and neither sees the other's
  # half-finished render appear under them.
  def change
    create_table :certificate_previews, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid, index: false
      t.references :event, null: false, foreign_key: true, type: :uuid, index: false

      # pending -> ready | failed. See CertificatePreview::STATUSES.
      t.string :status, null: false, default: "pending"

      # The Active Storage blob holding the .odt that was rendered. Stored as
      # a plain id rather than a foreign key: blobs are purged on their own
      # schedule and a preview outliving its template is fine (the row just
      # becomes unrenderable, which the job reports as failed) — a real FK
      # would instead block the purge or cascade a delete we don't want.
      t.bigint :template_blob_id, null: false

      # The finished PDF, as a URL string. Same choice and same reasoning as
      # Certificate#file_url and Event#banner_url — see Certificates::RenderPdf's
      # class comment for why this codebase avoids has_one_attached.
      t.string :file_url

      # Machine-readable, for translating in the UI. Never a raw exception
      # message: those carry file paths and soffice internals that mean
      # nothing to an organizer.
      t.string :error_code

      t.timestamps
    end

    # One live preview per organizer per event — the bound on this table.
    add_index :certificate_previews, [ :user_id, :event_id ], unique: true,
              name: "index_certificate_previews_one_per_user_per_event"

    # The sweep's access path: "everything older than N hours".
    add_index :certificate_previews, :updated_at

    add_check_constraint :certificate_previews,
      "status IN ('pending', 'ready', 'failed')",
      name: "certificate_previews_status_check"
  end
end
