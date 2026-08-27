# Renames the event-moderation-lock columns added in
# 20260827000000_add_frozen_to_events.rb from "frozen"/"freeze" to
# "suspended"/"suspension" — matching the same wording already used for
# User#suspend! (suspended_at/suspension_reason), since this is the same
# concept (an admin-only-reversible lock) applied to an event instead of an
# account. rename_column (not add/drop) so no data is lost.
#
# The index rename is done defensively rather than via a bare rename_index:
# environments whose local DB was schema:load'ed at different points in this
# feature's history may or may not actually have "index_events_on_frozen_at"
# present under that exact name. If it's there, rename it in place; if not,
# just make sure an index on the new column exists either way, rather than
# blowing up a migration that already successfully renamed both columns.
class RenameFrozenToSuspendedOnEvents < ActiveRecord::Migration[8.1]
  def change
    rename_column :events, :frozen_at, :suspended_at
    rename_column :events, :freeze_reason, :suspension_reason

    if index_name_exists?(:events, "index_events_on_frozen_at")
      rename_index :events, "index_events_on_frozen_at", "index_events_on_suspended_at"
    elsif !index_exists?(:events, :suspended_at)
      add_index :events, :suspended_at, where: "suspended_at IS NOT NULL"
    end
  end
end
