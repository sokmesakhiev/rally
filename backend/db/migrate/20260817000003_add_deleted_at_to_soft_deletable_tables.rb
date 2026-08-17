class AddDeletedAtToSoftDeletableTables < ActiveRecord::Migration[8.1]
  # Soft-delete for the four models an organizer/admin can meaningfully
  # "remove" today (Event, Registration, Survey, WaitlistEntry — see each
  # model's #discard!). Deliberately NOT a Rails `default_scope` — a
  # `belongs_to :event` (etc.) on another model would silently inherit that
  # scope too, so e.g. `registration.event` could return nil the moment its
  # event was discarded, even though the registration row itself is untouched.
  # Each model instead exposes explicit `.kept`/`.discarded` scopes, and
  # callers opt in at the read call sites that actually need filtering —
  # same pattern already used for Registration.active (see refund work).
  def change
    add_column :events, :deleted_at, :datetime
    add_column :registrations, :deleted_at, :datetime
    add_column :surveys, :deleted_at, :datetime
    add_column :waitlist_entries, :deleted_at, :datetime

    add_index :events, :deleted_at
    add_index :registrations, :deleted_at
    add_index :surveys, :deleted_at
    add_index :waitlist_entries, :deleted_at
  end
end
